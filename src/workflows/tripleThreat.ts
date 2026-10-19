// Durable DBOS workflow for the Triple-Threat pipeline. It replaced an earlier
// PowerShell orchestrator.
//
// Mirrors ansiblePatchInventoryWorkflow's shape: idempotent steps, natural-key
// upserts so replay after a crash never duplicates work, DBOS.recv for
// approval gates. What's different: 8 stages instead of 1, 5 distinct gates
// (one @DBOS.recv topic each) instead of 1, and a blocker-workshop /
// validation-warnings loop where Felton resolves items via HTTP routes
// (routes.ts) while the workflow just waits on the corresponding gate.
//
// Round/stage/blocker/warning state is visible via the /tt-workflows/* routes
// and the DBOS console.
import { DBOS } from "@dbos-inc/dbos-sdk";
import type { AgentRunnerConfig } from "../agentRunnerClient.js";
import { getAgentJobArtifact, getAgentJobStatus, submitAgentJob } from "../agentRunnerClient.js";
import type { DbosConfig } from "../config.js";
import {
  appendWorkflowEvent,
  createDbosPool,
  getTtStageJob,
  listTtBlockers,
  listTtWarnings,
  setWorkflowStatus,
  upsertTtBlocker,
  upsertTtStageJob,
  upsertWorkflowRequest,
  type DbosPool
} from "../store.js";
import { TT_MAX_REMEDIATION_PASSES } from "../types.js";
import type { TripleThreatRequest, TtStage, TtStageKey } from "../types.js";
import { buildRemediationBlock, parseValidationVerdict, STAGE_DEFINITIONS, type StageContext } from "./tripleThreatPrompts.js";

const GATE_TIMEOUT_SECONDS = 7 * 24 * 60 * 60; // 7 days, matching the ansible workflow's approval gate
const STAGE_POLL_INTERVAL_SECONDS = 20;
const STAGE_MAX_POLLS = 180; // 1 hour ceiling per stage; specialist stages run far longer than an ansible playbook

// The adjudication stage's output has to become tt_blockers rows or the
// blocker workshop stays empty. Two things make that awkward:
//
//   1. What runStageStep hands back (and what tt_stage_jobs stores) is the
//      agent-runner result *envelope* -- a JSON object with an `is_error`,
//      `usage`, ... and a `result` string. The blocker content lives inside
//      `result`, not at the top level.
//   2. The prose manifest inside `result` ("B1 — title", "Question:", ...)
//      is written for a human and drifts in format run to run.
//
// So: unwrap the envelope, then prefer a machine-readable fenced ```json
// block the adjudication prompt now asks the agent to append
// (tripleThreatPrompts.ts), and only fall back to scraping the prose if that
// block is missing or unparseable.
export interface ParsedAdjudicationBlocker {
  blockerId: string;
  title: string;
  question: string | null;
  whyItBlocks: string | null;
  recommendation: string | null;
  evidenceRequired: boolean;
}

// runStageStep returns the raw agent-runner payload. Historically that has
// been a JSON envelope ({ is_error, result, usage, ... }); tolerate a plain
// string too, in case that ever changes or an older job is reprocessed.
function unwrapAgentResult(raw: string): string {
  try {
    const env: unknown = JSON.parse(raw);
    if (env && typeof env === "object" && typeof (env as { result?: unknown }).result === "string") {
      return (env as { result: string }).result;
    }
  } catch {
    // not an envelope -- treat the whole thing as the text
  }
  return raw;
}

function toNullableString(value: unknown): string | null {
  if (value == null) return null;
  const s = String(value).trim();
  return s.length ? s : null;
}

function coerceEvidenceRequired(value: unknown): boolean {
  if (typeof value === "boolean") return value;
  if (value == null) return true;
  // "no" / "no — risk accepted" => not required; "yes" / "conditional" / "" => required
  return !/^\s*no\b/i.test(String(value));
}

const BLOCKER_JSON_BLOCK_RE = /```json\s*([\s\S]*?)```/i;

function parseBlockerJsonBlock(text: string): ParsedAdjudicationBlocker[] {
  const match = text.match(BLOCKER_JSON_BLOCK_RE);
  if (!match) return [];
  let data: unknown;
  try {
    data = JSON.parse(match[1].trim());
  } catch {
    return [];
  }
  const list = Array.isArray(data)
    ? data
    : Array.isArray((data as { blockers?: unknown })?.blockers)
      ? (data as { blockers: unknown[] }).blockers
      : [];

  const out: ParsedAdjudicationBlocker[] = [];
  for (const item of list) {
    if (!item || typeof item !== "object") continue;
    const rec = item as Record<string, unknown>;
    const idMatch = String(rec.id ?? rec.blockerId ?? "").match(/(\d+)/);
    const title = toNullableString(rec.title);
    if (!idMatch || !title) continue;
    out.push({
      blockerId: `B${idMatch[1]}`,
      title,
      question: toNullableString(rec.question),
      whyItBlocks: toNullableString(rec.whyItBlocks ?? rec.why_it_blocks),
      recommendation: toNullableString(rec.recommendation),
      evidenceRequired: coerceEvidenceRequired(rec.evidenceRequired ?? rec.evidence_required)
    });
  }
  return dedupeSortBlockers(out);
}

const BLOCKER_HEADING_RE = /^\s*#{0,6}\s*\*{0,2}\s*B(\d+)\s*\*{0,2}\s*[—–-]\s*(.+?)\s*\*{0,2}\s*$/;
const BLOCKER_FIELD_RE =
  /^\s*\*{0,2}\s*(Question|Why it blocks|Recommendation|Evidence required|Gate|Alternatives considered|Consequences)\s*\*{0,2}\s*:\s*(.*)$/i;

// Fallback only: scrape the human prose manifest. Tolerant of optional "#"
// heading markers, "**bold**" around the label/ID, and the ID/title
// separator being em-dash, en-dash or a hyphen. Wrapped field values are
// re-joined until the next label or heading.
function parseBlockerProse(text: string): ParsedAdjudicationBlocker[] {
  const out: ParsedAdjudicationBlocker[] = [];
  let current: ParsedAdjudicationBlocker | null = null;
  let openField: "question" | "whyItBlocks" | "recommendation" | null = null;

  const flush = (): void => {
    if (current) out.push(current);
    current = null;
    openField = null;
  };

  for (const line of text.split(/\r?\n/)) {
    const heading = line.match(BLOCKER_HEADING_RE);
    if (heading) {
      flush();
      current = {
        blockerId: `B${heading[1]}`,
        title: heading[2].trim(),
        question: null,
        whyItBlocks: null,
        recommendation: null,
        evidenceRequired: true
      };
      continue;
    }
    if (!current) continue;

    const field = line.match(BLOCKER_FIELD_RE);
    if (field) {
      const label = field[1].toLowerCase();
      const value = field[2].trim();
      if (label === "question") {
        current.question = value || null;
        openField = "question";
      } else if (label === "why it blocks") {
        current.whyItBlocks = value || null;
        openField = "whyItBlocks";
      } else if (label === "recommendation") {
        current.recommendation = value || null;
        openField = "recommendation";
      } else if (label === "evidence required") {
        current.evidenceRequired = !/^\s*no\b/i.test(value);
        openField = null;
      } else {
        openField = null; // Gate / Alternatives considered / Consequences — not stored
      }
      continue;
    }

    if (openField && line.trim()) {
      const existing = current[openField];
      current[openField] = existing ? `${existing} ${line.trim()}` : line.trim();
    }
  }
  flush();
  return dedupeSortBlockers(out);
}

function dedupeSortBlockers(blockers: ParsedAdjudicationBlocker[]): ParsedAdjudicationBlocker[] {
  const byId = new Map<string, ParsedAdjudicationBlocker>();
  for (const b of blockers) byId.set(b.blockerId, b);
  return [...byId.values()].sort((a, b) => Number(a.blockerId.slice(1)) - Number(b.blockerId.slice(1)));
}

export function parseAdjudicationBlockers(rawArtifact: string): ParsedAdjudicationBlocker[] {
  const text = unwrapAgentResult(rawArtifact);
  const fromJson = parseBlockerJsonBlock(text);
  if (fromJson.length) return fromJson;
  return parseBlockerProse(text);
}

let pool: DbosPool | null = null;
let agentRunnerConfig: AgentRunnerConfig | null = null;
// Optional notification hook, set once by the host service after the DBOS
// layer has bootstrapped. Left null (no-op) when nothing is registered, so
// this workflow behaves identically whether or not a notifier exists. No
// notifier is wired up by default: gate approvals happen in The Arena.
let notifyTriplethreat: ((message: string) => Promise<void>) | null = null;

export function setTtNotifier(fn: (message: string) => Promise<void>): void {
  notifyTriplethreat = fn;
}

// Called once from bootstrap.ts before DBOS.launch(), same convention as
// configureAnsibleWorkflows.
export function configureTripleThreatWorkflows(config: DbosConfig): void {
  pool = createDbosPool(config.dbosDatabaseUrl);
  agentRunnerConfig = { baseUrl: config.agentRunnerUrl, token: config.agentRunnerToken };
}

function requirePool(): DbosPool {
  if (!pool) throw new Error("configureTripleThreatWorkflows() was not called before workflow execution");
  return pool;
}

function requireAgentRunnerConfig(): AgentRunnerConfig {
  if (!agentRunnerConfig) throw new Error("configureTripleThreatWorkflows() was not called before workflow execution");
  if (!agentRunnerConfig.baseUrl) {
    throw new Error("AGENT_RUNNER_URL is not set — agent-runner-service deployment target has not been configured yet");
  }
  return agentRunnerConfig;
}

export interface GateApproval {
  approvedBy: string;
  // Only the finalize-validated-runbook gate understands "remediate": it runs
  // one Stage 7 + Stage 8 remediation pass and waits at the gate again.
  action?: "approve" | "remediate";
}

export interface TripleThreatResult {
  workflowId: string;
  status: string;
}

async function cancelForTimeout(workflowId: string, gate: string): Promise<TripleThreatResult> {
  await setWorkflowStatus(requirePool(), workflowId, "cancelled");
  await appendWorkflowEvent(requirePool(), { workflowId, eventType: "gate_timed_out", payload: { gate } });
  await TripleThreatWorkflows.notifyStep(
    `⚠️ Triple-Threat \`${workflowId}\` was cancelled — the \`${gate}\` gate timed out after 7 days without approval.`
  );
  return { workflowId, status: "cancelled" };
}

export class TripleThreatWorkflows {
  @DBOS.step()
  static async runStageStep(workflowId: string, stage: TtStage, ctx: StageContext, jobKey?: TtStageKey): Promise<string> {
    const definition = STAGE_DEFINITIONS[stage];
    // A remediation pass stores its job under its own key ("validation:r1") so
    // the stage's first-run job is never reused as if it were the new run.
    const key: TtStageKey = jobKey ?? stage;
    const existing = await getTtStageJob(requirePool(), workflowId, key);
    let runnerJobId = existing?.runnerJobId ?? null;

    if (!runnerJobId) {
      const prompt = definition.buildPrompt(ctx);
      const submitted = await submitAgentJob(requireAgentRunnerConfig(), {
        specialist: definition.specialist,
        stage,
        projectSlug: ctx.projectSlug,
        projectDir: ctx.projectDir,
        prompt,
        mode: definition.mode
      });
      runnerJobId = submitted.runnerJobId;
      await upsertTtStageJob(requirePool(), {
        workflowId,
        stage: key,
        specialist: definition.specialist,
        runnerJobId,
        status: submitted.status
      });
    }

    for (let poll = 0; poll < STAGE_MAX_POLLS; poll++) {
      const status = await getAgentJobStatus(requireAgentRunnerConfig(), runnerJobId);
      if (status.status === "succeeded" || status.status === "failed") {
        await upsertTtStageJob(requirePool(), {
          workflowId,
          stage: key,
          specialist: definition.specialist,
          runnerJobId,
          status: status.status
        });
        if (status.status === "failed") {
          throw new Error(`triple-threat stage ${stage} failed (runnerJobId=${runnerJobId})`);
        }
        const artifact = await getAgentJobArtifact(requireAgentRunnerConfig(), runnerJobId);
        await upsertTtStageJob(requirePool(), {
          workflowId,
          stage: key,
          specialist: definition.specialist,
          runnerJobId,
          status: status.status,
          content: artifact.content
        });
        await appendWorkflowEvent(requirePool(), {
          workflowId,
          eventType: `${stage}_completed`,
          payload: { runnerJobId, source: artifact.source, jobKey: key }
        });
        return artifact.content;
      }
      await DBOS.sleepSeconds(STAGE_POLL_INTERVAL_SECONDS);
    }
    throw new Error(`triple-threat stage ${stage} (runnerJobId=${runnerJobId}) did not reach a terminal state within the polling window`);
  }

  // A @DBOS.step(), not a plain function call in the workflow body, on
  // purpose: DBOS memoizes step results across replay, so a crash/restart
  // that re-runs this part of the workflow does NOT re-send the same
  // notification. Calling notifyTriplethreat() directly from workflow
  // code (like setWorkflowStatus/appendWorkflowEvent are, elsewhere in this
  // file) would double-post on replay, since a chat message isn't
  // idempotent the way a natural-key Postgres upsert is.
  @DBOS.step()
  static async notifyStep(message: string): Promise<void> {
    if (!notifyTriplethreat) return;
    await notifyTriplethreat(message);
  }

  // Turn the adjudication stage's free-text blocker manifest into tt_blockers
  // rows so the Arena / approvals blocker workshop actually has something to
  // render. Without this the manifest only ever lands in the filed artifact +
  // the stage job's stored content, and the workshop stays empty until someone POSTs
  // rows by hand (the state this replaced).
  //
  // @DBOS.step() so the parse + writes memoize across replay. upsertTtBlocker
  // keys on (workflow_id, blocker_id), so a replay — or a deliberate re-run
  // of this step for the same round — only refreshes the manifest-derived
  // fields (title / question / why-it-blocks / recommendation /
  // evidence_required). It never passes decision, evidence or verified, and
  // upsertTtBlocker's `coalesce($n, existing)` update means any operator
  // progress already recorded in the workshop is left untouched.
  @DBOS.step()
  static async ingestAdjudicationBlockersStep(workflowId: string, manifest: string): Promise<number> {
    const parsed = parseAdjudicationBlockers(manifest);
    for (const blocker of parsed) {
      await upsertTtBlocker(requirePool(), {
        workflowId,
        blockerId: blocker.blockerId,
        title: blocker.title,
        question: blocker.question,
        whyItBlocks: blocker.whyItBlocks,
        recommendation: blocker.recommendation,
        evidenceRequired: blocker.evidenceRequired
      });
    }
    await appendWorkflowEvent(requirePool(), {
      workflowId,
      eventType: "adjudication_blockers_ingested",
      payload: { count: parsed.length, blockerIds: parsed.map((b) => b.blockerId) }
    });
    return parsed.length;
  }

  // No code-side note-filing relay: the specialist itself files its own
  // stage output directly via mcp__geekygramps__write_memory (vector memory) -- see
  // agent-runner-service's --allowedTools and tripleThreatPrompts.ts's
  // vectorMemoryInstruction()/runbookVectorMemoryInstruction(). The workflow
  // never creates notes itself.

  @DBOS.workflow()
  static async tripleThreatWorkflow(input: TripleThreatRequest): Promise<TripleThreatResult> {
    const workflowId = DBOS.workflowID;
    if (!workflowId) throw new Error("tripleThreatWorkflow invoked outside a DBOS workflow context");

    await upsertWorkflowRequest(requirePool(), {
      workflowId,
      workflowType: "triple_threat",
      status: "requested",
      requestedBy: input.requestedBy,
      idempotencyKey: input.idempotencyKey,
      params: {
        projectSlug: input.projectSlug,
        projectName: input.projectName,
        projectDir: input.projectDir,
        round: input.round,
        triliumParentNoteId: input.triliumParentNoteId ?? null
      }
    });

    const artifacts: StageContext["priorArtifacts"] = {};
    const buildCtx = (extra?: string): StageContext => ({
      projectName: input.projectName,
      projectSlug: input.projectSlug,
      projectDir: input.projectDir,
      round: input.round,
      priorArtifacts: artifacts,
      extra
    });

    await setWorkflowStatus(requirePool(), workflowId, "executing");
    // Only the design stage gets the launch-time source text; later stages
    // build on its artifact, and DBOS records every step's input.
    artifacts.design = await TripleThreatWorkflows.runStageStep(workflowId, "design", {
      ...buildCtx(),
      sourceContent: input.sourceContent
    });
    artifacts.architecture = await TripleThreatWorkflows.runStageStep(workflowId, "architecture", buildCtx());

    await setWorkflowStatus(requirePool(), workflowId, "awaiting_approval");
    await appendWorkflowEvent(requirePool(), { workflowId, eventType: "awaiting_gate", payload: { gate: "post-architecture" } });
    await TripleThreatWorkflows.notifyStep(
      `🔔 Triple-Threat \`${workflowId}\` (${input.projectName}) is waiting on you — approve \`post-architecture\` in the Arena to continue`
    );
    const postArchitecture = await DBOS.recv<GateApproval>("gate:post-architecture", GATE_TIMEOUT_SECONDS);
    if (!postArchitecture) return cancelForTimeout(workflowId, "post-architecture");
    await appendWorkflowEvent(requirePool(), {
      workflowId,
      eventType: "gate_approved",
      payload: { gate: "post-architecture", approvedBy: postArchitecture.approvedBy }
    });

    await setWorkflowStatus(requirePool(), workflowId, "executing");
    const [codexReview, antigravityReview] = await Promise.all([
      TripleThreatWorkflows.runStageStep(workflowId, "codex_review", buildCtx()),
      TripleThreatWorkflows.runStageStep(workflowId, "antigravity_review", buildCtx())
    ]);
    artifacts.codex_review = codexReview;
    artifacts.antigravity_review = antigravityReview;

    artifacts.adjudication = await TripleThreatWorkflows.runStageStep(workflowId, "adjudication", buildCtx());

    // Seed the blocker workshop from the manifest the adjudication stage just
    // produced. Blockers are still decided/verified operator-paced through the
    // /tt-workflows/:id/blockers routes — this only creates the rows so the
    // workshop isn't empty when Felton opens it at the gate below.
    const ingestedBlockerCount = await TripleThreatWorkflows.ingestAdjudicationBlockersStep(
      workflowId,
      artifacts.adjudication
    );

    await setWorkflowStatus(requirePool(), workflowId, "awaiting_approval");
    await appendWorkflowEvent(requirePool(), { workflowId, eventType: "awaiting_gate", payload: { gate: "finalize-adjudication" } });
    await TripleThreatWorkflows.notifyStep(
      `🔔 Triple-Threat \`${workflowId}\` (${input.projectName}) — ${ingestedBlockerCount} blocker(s) in the workshop. Work them, then approve \`finalize-adjudication\` in the Arena to continue`
    );
    const finalizeAdjudication = await DBOS.recv<GateApproval>("gate:finalize-adjudication", GATE_TIMEOUT_SECONDS);
    if (!finalizeAdjudication) return cancelForTimeout(workflowId, "finalize-adjudication");
    await appendWorkflowEvent(requirePool(), {
      workflowId,
      eventType: "gate_approved",
      payload: { gate: "finalize-adjudication", approvedBy: finalizeAdjudication.approvedBy }
    });

    const blockers = await listTtBlockers(requirePool(), workflowId);
    // The register stage judges whether each blocker is settled, so it needs
    // the operator's decision AND evidence AND verified flag, not just the
    // decision text. Passing only the decision made every blocker look open
    // from the adjudication text alone.
    const finalizedManifest = blockers
      .map((b) =>
        [
          `${b.blockerId} — ${b.title} [${b.verified ? "VERIFIED" : b.status}]`,
          `  Decision: ${b.decision ?? "(no decision recorded)"}`,
          `  Evidence: ${b.evidence ?? "(none recorded)"}`
        ].join("\n")
      )
      .join("\n\n");

    await setWorkflowStatus(requirePool(), workflowId, "executing");
    artifacts.decision_register = await TripleThreatWorkflows.runStageStep(
      workflowId,
      "decision_register",
      buildCtx(finalizedManifest)
    );
    // The register stage is told to stop and file nothing when the manifest
    // isn't final. That used to look identical to success at this gate, and
    // implementation then ran with no register. Surface it loudly instead.
    const registerDeclined = /Decision Register not produced|Manifest not finalized/i.test(
      unwrapAgentResult(artifacts.decision_register)
    );
    await setWorkflowStatus(requirePool(), workflowId, "awaiting_approval");
    await appendWorkflowEvent(requirePool(), {
      workflowId,
      eventType: "awaiting_gate",
      payload: { gate: "post-decision-register", registerDeclined }
    });
    await TripleThreatWorkflows.notifyStep(
      registerDeclined
        ? `⚠️ Triple-Threat \`${workflowId}\` (${input.projectName}) — the decision register was NOT produced (manifest not finalized). Approving \`post-decision-register\` will run implementation with no register. Read the decision_register artifact first.`
        : `🔔 Triple-Threat \`${workflowId}\` (${input.projectName}) is waiting on you — approve \`post-decision-register\` in the Arena to continue`
    );
    const postDecisionRegister = await DBOS.recv<GateApproval>("gate:post-decision-register", GATE_TIMEOUT_SECONDS);
    if (!postDecisionRegister) return cancelForTimeout(workflowId, "post-decision-register");
    await appendWorkflowEvent(requirePool(), {
      workflowId,
      eventType: "gate_approved",
      payload: { gate: "post-decision-register", approvedBy: postDecisionRegister.approvedBy }
    });

    await setWorkflowStatus(requirePool(), workflowId, "executing");
    artifacts.implementation = await TripleThreatWorkflows.runStageStep(workflowId, "implementation", buildCtx());

    await setWorkflowStatus(requirePool(), workflowId, "awaiting_approval");
    await appendWorkflowEvent(requirePool(), { workflowId, eventType: "awaiting_gate", payload: { gate: "post-implementation" } });
    await TripleThreatWorkflows.notifyStep(
      `🔔 Triple-Threat \`${workflowId}\` (${input.projectName}) is waiting on you — approve \`post-implementation\` in the Arena to continue`
    );
    const postImplementation = await DBOS.recv<GateApproval>("gate:post-implementation", GATE_TIMEOUT_SECONDS);
    if (!postImplementation) return cancelForTimeout(workflowId, "post-implementation");
    await appendWorkflowEvent(requirePool(), {
      workflowId,
      eventType: "gate_approved",
      payload: { gate: "post-implementation", approvedBy: postImplementation.approvedBy }
    });

    await setWorkflowStatus(requirePool(), workflowId, "executing");
    artifacts.validation = await TripleThreatWorkflows.runStageStep(workflowId, "validation", buildCtx());

    // Decided 2026-08-28: TT is AI-assisted human gating, not autonomy -- no
    // auto-remediation loop back to Stage 7 on a Fail. Stage 8 runs once;
    // this just reliably classifies and surfaces the verdict at the gate
    // instead of leaving Felton to read raw prose to find out what happened.
    // See tripleThreatPrompts.ts's header comment on parseValidationVerdict.
    const validationVerdict = parseValidationVerdict(artifacts.validation);
    await appendWorkflowEvent(requirePool(), {
      workflowId,
      eventType: "validation_verdict",
      payload: { verdict: validationVerdict }
    });

    // Validation-warnings loop: same pattern as blockers, via
    // /tt-workflows/:id/warnings routes.
    await setWorkflowStatus(requirePool(), workflowId, "awaiting_approval");
    await appendWorkflowEvent(requirePool(), {
      workflowId,
      eventType: "awaiting_gate",
      payload: { gate: "finalize-validated-runbook" }
    });
    await TripleThreatWorkflows.notifyStep(
      `🔔 Triple-Threat \`${workflowId}\` (${input.projectName}) — Stage 8 verdict: **${validationVerdict}**. Approve \`finalize-validated-runbook\` in the Arena to continue`
    );
    // This gate is a loop. Approve ends it. "remediate" (a human click, via
    // POST /tt-workflows/:id/remediate) runs one Stage 7 + Stage 8 pass with
    // the validation failures as written context, then waits here again.
    // Nothing repeats on its own, and TT_MAX_REMEDIATION_PASSES caps the total.
    let currentVerdict = validationVerdict;
    let remediationPass = 0;
    let finalizeValidatedRunbook: GateApproval | null = null;
    while (true) {
      const message = await DBOS.recv<GateApproval>("gate:finalize-validated-runbook", GATE_TIMEOUT_SECONDS);
      if (!message) return cancelForTimeout(workflowId, "finalize-validated-runbook");
      if (message.action !== "remediate") {
        finalizeValidatedRunbook = message;
        break;
      }
      if (currentVerdict === "PASS" || remediationPass >= TT_MAX_REMEDIATION_PASSES) {
        await TripleThreatWorkflows.notifyStep(
          `⚠️ Triple-Threat \`${workflowId}\` — remediation refused (${currentVerdict === "PASS" ? "validation already passed" : `all ${TT_MAX_REMEDIATION_PASSES} passes used`}). Approve \`finalize-validated-runbook\` to continue.`
        );
        continue;
      }
      remediationPass += 1;
      await appendWorkflowEvent(requirePool(), {
        workflowId,
        eventType: "remediation_started",
        payload: { pass: remediationPass, verdict: currentVerdict, requestedBy: message.approvedBy }
      });
      await setWorkflowStatus(requirePool(), workflowId, "executing");
      await TripleThreatWorkflows.notifyStep(
        `🛠️ Triple-Threat \`${workflowId}\` (${input.projectName}) — remediation pass ${remediationPass} of ${TT_MAX_REMEDIATION_PASSES}: re-running implementation against the validation findings.`
      );
      const openWarnings = (await listTtWarnings(requirePool(), workflowId))
        .filter((w) => !(w.status === "resolved" && w.verified))
        .map((w) => `${w.warningId}: ${w.description}`);
      const remediation = buildRemediationBlock({
        pass: remediationPass,
        maxPasses: TT_MAX_REMEDIATION_PASSES,
        verdict: currentVerdict,
        validationReport: unwrapAgentResult(artifacts.validation ?? "").slice(0, 40_000),
        openWarnings
      });
      artifacts.implementation = await TripleThreatWorkflows.runStageStep(
        workflowId,
        "implementation",
        { ...buildCtx(), remediation },
        `implementation:r${remediationPass}`
      );
      artifacts.validation = await TripleThreatWorkflows.runStageStep(
        workflowId,
        "validation",
        buildCtx(),
        `validation:r${remediationPass}`
      );
      currentVerdict = parseValidationVerdict(artifacts.validation);
      await appendWorkflowEvent(requirePool(), {
        workflowId,
        eventType: "validation_verdict",
        payload: { verdict: currentVerdict, remediationPass }
      });
      await appendWorkflowEvent(requirePool(), { workflowId, eventType: "remediation_done", payload: { pass: remediationPass, verdict: currentVerdict } });
      await setWorkflowStatus(requirePool(), workflowId, "awaiting_approval");
      await appendWorkflowEvent(requirePool(), { workflowId, eventType: "awaiting_gate", payload: { gate: "finalize-validated-runbook" } });
      await TripleThreatWorkflows.notifyStep(
        `🔔 Triple-Threat \`${workflowId}\` (${input.projectName}) — remediation pass ${remediationPass} done, Stage 8 verdict: **${currentVerdict}**. Approve \`finalize-validated-runbook\`, or remediate again (${TT_MAX_REMEDIATION_PASSES - remediationPass} left).`
      );
    }
    await appendWorkflowEvent(requirePool(), {
      workflowId,
      eventType: "gate_approved",
      payload: { gate: "finalize-validated-runbook", approvedBy: finalizeValidatedRunbook.approvedBy }
    });

    await setWorkflowStatus(requirePool(), workflowId, "synchronized");
    await appendWorkflowEvent(requirePool(), { workflowId, eventType: "complete", payload: {} });
    await TripleThreatWorkflows.notifyStep(`✅ Triple-Threat \`${workflowId}\` (${input.projectName}) finished — all 8 stages and every gate complete.`);
    return { workflowId, status: "synchronized" };
  }
}
