// Plain authenticated HTTP endpoints under /tt-workflows/* — same pattern as
// routes.ts's /workflows/* (rides the existing Fastify instance + X-MCP-Token
// gate, not MCP tools, so no chat-agent tool call can reach these).
import { createHash } from "node:crypto";
import { DBOS } from "@dbos-inc/dbos-sdk";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { renderApprovalsPage } from "./approvalsPage.js";
import { TT_GATES, TT_MAX_REMEDIATION_PASSES, TT_STAGES, TtGate } from "./types.js";
import { parseValidationVerdict } from "./workflows/tripleThreatPrompts.js";
import {
  createDbosPool,
  getLatestPendingGate,
  getLatestTtStageJob,
  getTtStageJob,
  getWorkflowRequest,
  listTtBlockers,
  listTtStageJobs,
  listTtWarnings,
  listWorkflowEvents,
  listWorkflowRequests,
  nextTtBlockerId,
  nextTtWarningId,
  upsertTtBlocker,
  upsertTtWarning
} from "./store.js";
import { loadDbosConfig } from "./config.js";
import {
  createTtNote,
  isRetriableProjectionError,
  TriliumProjectionDisabledError
} from "./trilium-projector.js";
import { TripleThreatWorkflows } from "./workflows/tripleThreat.js";
import type { GateApproval } from "./workflows/tripleThreat.js";
import type { TripleThreatRequest, TtBlockerRecord, TtWarningRecord } from "./types.js";

export const startTripleThreatSchema = z.object({
  projectSlug: z.string().min(1).max(120),
  projectName: z.string().min(1).max(200),
  projectDir: z.string().min(1).max(300),
  round: z.number().int().min(1),
  requestedBy: z.string().min(1).max(120),
  triliumParentNoteId: z.string().min(1).max(255).optional(),
  // Source material read from the vault by the operator's browser (the agent
  // runner can't reach the vault) -- same cap as Gauntlet's proposal.
  sourceContent: z.string().max(500_000).optional()
});

export const gateApprovalSchema = z.object({
  approvedBy: z.string().min(1).max(120)
});

export const createBlockerSchema = z.object({
  title: z.string().min(1).max(300),
  question: z.string().max(2000).optional(),
  whyItBlocks: z.string().max(2000).optional(),
  recommendation: z.string().max(2000).optional(),
  evidenceRequired: z.boolean().optional()
});

export const decisionSchema = z.object({
  decision: z.string().min(1).max(4000),
  evidence: z.string().max(4000).optional()
});

export const createWarningSchema = z.object({
  description: z.string().min(1).max(2000)
});

export const resolutionSchema = z.object({
  resolution: z.string().min(1).max(4000),
  evidence: z.string().max(4000).optional()
});

interface TtWorkflowClasses {
  TripleThreatWorkflows: typeof TripleThreatWorkflows;
}

const pool_ = createDbosPool(loadDbosConfig().dbosDatabaseUrl);

function isTtGate(value: string): value is TtGate {
  return (TT_GATES as readonly string[]).includes(value);
}

// Same create-only, no-op-if-disabled behavior as the workflow's own
// createStageNoteStep — swallows "not configured"/transient errors so a
// blocker/warning can still be verified even if Trilium projection is off
// or briefly unreachable; the note simply doesn't get created that time.
async function tryCreateTriliumNote(parentNoteId: string, title: string, markdownBody: string): Promise<string | null> {
  try {
    const result = await createTtNote(loadDbosConfig().trilium, { parentNoteId, title, markdownBody });
    return result.noteId;
  } catch (error) {
    if (error instanceof TriliumProjectionDisabledError || isRetriableProjectionError(error)) return null;
    throw error;
  }
}

export function registerTripleThreatRoutes(app: FastifyInstance, classes: TtWorkflowClasses): void {
  const pool = createDbosPool(loadDbosConfig().dbosDatabaseUrl);

  // Blocker decisions/evidence are typed into the Arena page and saved to the
  // workflow DB, which no agent can read. File each save to vector memory too
  // so later stages and agents can search it. Best-effort: a memory failure
  // must never fail the operator's save. (ragStore is decorated onto the app
  // by the vector-memory integration at image build time.)
  async function fileBlockerToMemory(workflowId: string, blocker: TtBlockerRecord): Promise<void> {
    try {
      const store = (app as unknown as { ragStore?: { write(input: unknown, actor: string): Promise<unknown> } }).ragStore;
      if (!store) return;
      const row = await getWorkflowRequest(pool, workflowId);
      const params = (row?.params ?? {}) as { projectSlug?: string; projectName?: string; round?: number };
      if (!params.projectSlug) return;
      const projectName = params.projectName ?? params.projectSlug;
      const content = [
        `# ${blocker.blockerId} — ${blocker.title}`,
        `**Status:** ${blocker.verified ? "VERIFIED" : blocker.status}`,
        `**Question:** ${blocker.question ?? "(none recorded)"}`,
        `**Why it blocks:** ${blocker.whyItBlocks ?? "(none recorded)"}`,
        `**Recommendation:** ${blocker.recommendation ?? "(none recorded)"}`,
        "",
        `**Decision (Felton):** ${blocker.decision ?? "(none recorded)"}`,
        `**Evidence (Felton):** ${blocker.evidence ?? "(none recorded)"}`
      ].join("\n");
      await store.write(
        {
          note_id: `tt-${params.projectSlug}-r${params.round ?? 0}-blocker-${blocker.blockerId}`,
          title: `${projectName} — ${blocker.blockerId} ${blocker.title}`,
          content,
          project: params.projectSlug,
          doc_type: "tt_blocker",
          ancestry: [projectName, `Round ${params.round ?? 0}`, "Blockers"],
          attributes: { recordedBy: "felton via Arena" }
        },
        "claude"
      );
    } catch (error) {
      app.log.warn({ err: error, workflowId, blockerId: blocker.blockerId }, "failed to file blocker to vector memory");
    }
  }

  // Same for validation warnings (the Stage 8 loop).
  async function fileWarningToMemory(workflowId: string, warning: TtWarningRecord): Promise<void> {
    try {
      const store = (app as unknown as { ragStore?: { write(input: unknown, actor: string): Promise<unknown> } }).ragStore;
      if (!store) return;
      const row = await getWorkflowRequest(pool, workflowId);
      const params = (row?.params ?? {}) as { projectSlug?: string; projectName?: string; round?: number };
      if (!params.projectSlug) return;
      const projectName = params.projectName ?? params.projectSlug;
      const content = [
        `# ${warning.warningId} — ${warning.description}`,
        `**Status:** ${warning.verified ? "VERIFIED" : warning.status}`,
        "",
        `**Resolution (Felton):** ${warning.resolution ?? "(none recorded)"}`,
        `**Evidence (Felton):** ${warning.evidence ?? "(none recorded)"}`
      ].join("\n");
      await store.write(
        {
          note_id: `tt-${params.projectSlug}-r${params.round ?? 0}-warning-${warning.warningId}`,
          title: `${projectName} — ${warning.warningId} ${warning.description}`.slice(0, 500),
          content,
          project: params.projectSlug,
          doc_type: "tt_warning",
          ancestry: [projectName, `Round ${params.round ?? 0}`, "Warnings"],
          attributes: { recordedBy: "felton via Arena" }
        },
        "claude"
      );
    } catch (error) {
      app.log.warn({ err: error, workflowId, warningId: warning.warningId }, "failed to file warning to vector memory");
    }
  }

  // One note per TT run: status, stage results, the gate/approval timeline, and
  // every blocker/warning with its decision and evidence. Filed so the run
  // exists in vector memory for good, not only in the workflow DB. Unchanged
  // content is skipped (hash kept in process memory) so periodic refreshes
  // don't re-embed the same text.
  const filedRunHashes = new Map<string, string>();

  async function fileRunRecordToMemory(workflowId: string): Promise<boolean> {
    const store = (app as unknown as { ragStore?: { write(input: unknown, actor: string): Promise<unknown> } }).ragStore;
    if (!store) return false;
    const row = await getWorkflowRequest(pool, workflowId);
    if (!row || row.workflowType !== "triple_threat") return false;
    const params = (row.params ?? {}) as { projectSlug?: string; projectName?: string; round?: number };
    if (!params.projectSlug) return false;
    const projectName = params.projectName ?? params.projectSlug;
    const round = params.round ?? 0;
    const [events, blockers, warnings, jobs] = await Promise.all([
      listWorkflowEvents(pool, workflowId),
      listTtBlockers(pool, workflowId),
      listTtWarnings(pool, workflowId),
      Promise.all(TT_STAGES.map((stage) => getTtStageJob(pool, workflowId, stage)))
    ]);
    const lines: string[] = [
      `# ${projectName} — Round ${round} run record`,
      `**Workflow:** ${workflowId}`,
      `**Status:** ${row.status}`,
      `**Requested by:** ${row.requestedBy}`,
      `**Created:** ${row.createdAt}`,
      `**Updated:** ${row.updatedAt}`,
      "",
      "## Stages",
      ...jobs.filter((job): job is NonNullable<typeof job> => job !== null).map((job) => `- ${job.stage}: ${job.status}`),
      "",
      "## Timeline",
      ...events.map((event) => `- ${event.createdAt} ${event.eventType} ${JSON.stringify(event.payload).slice(0, 300)}`),
      "",
      `## Blockers (${blockers.length})`,
      ...blockers.flatMap((b) => [
        `### ${b.blockerId} — ${b.title} [${b.verified ? "VERIFIED" : b.status}]`,
        `Question: ${b.question ?? "(none)"}`,
        `Decision: ${b.decision ?? "(none recorded)"}`,
        `Evidence: ${b.evidence ?? "(none recorded)"}`,
        ""
      ]),
      `## Warnings (${warnings.length})`,
      ...warnings.flatMap((w) => [
        `### ${w.warningId} — ${w.description} [${w.verified ? "VERIFIED" : w.status}]`,
        `Resolution: ${w.resolution ?? "(none recorded)"}`,
        `Evidence: ${w.evidence ?? "(none recorded)"}`,
        ""
      ])
    ];
    const content = lines.join("\n").slice(0, 250_000);
    const noteId = `tt-${params.projectSlug}-r${round}-run-record`;
    const hash = createHash("sha256").update(content).digest("hex");
    if (filedRunHashes.get(noteId) === hash) return false;
    await store.write(
      {
        note_id: noteId,
        title: `${projectName} — Round ${round} run record`,
        content,
        project: params.projectSlug,
        doc_type: "tt_run",
        ancestry: [projectName, `Round ${round}`],
        attributes: { workflowId, status: row.status }
      },
      "claude"
    );
    filedRunHashes.set(noteId, hash);
    return true;
  }

  // Walk every TT workflow in the DB. includeItems also re-files each blocker
  // and warning as its own note (used once, by the manual backfill route).
  async function backfillTtToMemory(includeItems: boolean): Promise<{ runs: number; filed: number; blockers: number; warnings: number; errors: number }> {
    const totals = { runs: 0, filed: 0, blockers: 0, warnings: 0, errors: 0 };
    const rows = (await listWorkflowRequests(pool, 200)).filter((r) => r.workflowType === "triple_threat");
    for (const row of rows) {
      totals.runs += 1;
      try {
        if (await fileRunRecordToMemory(row.workflowId)) totals.filed += 1;
        if (includeItems) {
          for (const blocker of await listTtBlockers(pool, row.workflowId)) {
            await fileBlockerToMemory(row.workflowId, blocker);
            totals.blockers += 1;
          }
          for (const warning of await listTtWarnings(pool, row.workflowId)) {
            await fileWarningToMemory(row.workflowId, warning);
            totals.warnings += 1;
          }
        }
      } catch (error) {
        totals.errors += 1;
        app.log.warn({ err: error, workflowId: row.workflowId }, "failed to file TT run to vector memory");
      }
    }
    return totals;
  }

  app.post("/tt-workflows/backfill-memory", async (_request, reply) => {
    const totals = await backfillTtToMemory(true);
    return reply.send(totals);
  });

  // Keep run records current (covers completion, which no route sees).
  const refreshTimer = setInterval(() => {
    backfillTtToMemory(false).catch((error) => app.log.warn({ err: error }, "TT run-record refresh failed"));
  }, 10 * 60 * 1000);
  refreshTimer.unref();
  setTimeout(() => {
    backfillTtToMemory(false).catch((error) => app.log.warn({ err: error }, "TT run-record refresh failed"));
  }, 90 * 1000).unref();

  app.post("/tt-workflows", async (request, reply) => {
    const parsed = startTripleThreatSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    }
    const input = parsed.data;
    const workflowId = `${input.projectSlug}-round-${input.round}`;
    const idempotencyKey = workflowId;

    const request_: TripleThreatRequest = {
      projectSlug: input.projectSlug,
      projectName: input.projectName,
      projectDir: input.projectDir,
      round: input.round,
      requestedBy: input.requestedBy,
      idempotencyKey,
      triliumParentNoteId: input.triliumParentNoteId,
      sourceContent: input.sourceContent
    };

    const handle = await DBOS.startWorkflow(classes.TripleThreatWorkflows, { workflowID: workflowId }).tripleThreatWorkflow(
      request_
    );
    return reply.code(202).send({ workflowId: handle.workflowID, status: "requested" });
  });

  app.get("/tt-approvals", async (_request, reply) => {
    reply.type("text/html").send(renderApprovalsPage(process.env.MCP_TOKEN || ""));
  });

  app.get("/tt-workflows-pending", async (_request, reply) => {
    const rows = (await listWorkflowRequests(pool, 200)).filter(
      (row) => row.workflowType === "triple_threat" && row.status === "awaiting_approval"
    );
    const workflows = await Promise.all(
      rows.map(async (row) => ({ ...row, pendingGate: await getLatestPendingGate(pool, row.workflowId) }))
    );
    return reply.send({ workflows });
  });

  app.get("/tt-workflows/:workflowId", async (request, reply) => {
    const { workflowId } = request.params as { workflowId: string };
    const row = await getWorkflowRequest(pool, workflowId);
    if (!row || row.workflowType !== "triple_threat") return reply.code(404).send({ error: "not_found" });
    const pendingGate = row.status === "awaiting_approval" ? await getLatestPendingGate(pool, workflowId) : null;
    // Derived, not stored -- same reasoning as the workflow's own call site
    // (tripleThreat.ts): no schema change needed, Stage 8's content is
    // already persisted, just re-parse it for display here too.
    // The newest validation counts: a remediation pass stores its own
    // "validation:rN" job, which supersedes the first run's.
    const validationJob = await getLatestTtStageJob(pool, workflowId, "validation");
    const validationVerdict = validationJob?.content ? parseValidationVerdict(validationJob.content) : null;
    const remediationPasses = (await listWorkflowEvents(pool, workflowId)).filter((e) => e.eventType === "remediation_started").length;
    return reply.send({ ...row, pendingGate, validationVerdict, remediationPasses, maxRemediationPasses: TT_MAX_REMEDIATION_PASSES });
  });

  app.get("/tt-workflows/:workflowId/events", async (request, reply) => {
    const { workflowId } = request.params as { workflowId: string };
    const events = await listWorkflowEvents(pool, workflowId);
    return reply.send({ events });
  });

  // Every stage's actual generated text (design doc, review, decision
  // register, ...) -- not just status. Persisted by upsertTtStageJob as soon
  // as a stage job succeeds (src/dbos/workflows/tripleThreat.ts:runStageStep).
  app.get("/tt-workflows/:workflowId/artifacts", async (request, reply) => {
    const { workflowId } = request.params as { workflowId: string };
    // All stage jobs, including remediation passes ("validation:r1", ...), in
    // the order they ran. First-run stages are listed in pipeline order.
    const jobs = await listTtStageJobs(pool, workflowId);
    const order = (key: string): number => {
      const base = TT_STAGES.indexOf(key.split(":")[0] as (typeof TT_STAGES)[number]);
      return key.includes(":") ? 1000 + Number(key.split(":r")[1] ?? 0) * 10 + base : base;
    };
    const artifacts = jobs
      .map((job) => ({ stage: job.stage, status: job.status, content: job.content }))
      .sort((a, b) => order(a.stage) - order(b.stage));
    return reply.send({ artifacts });
  });

  app.post("/tt-workflows/:workflowId/approve/:gate", async (request, reply) => {
    const { workflowId, gate } = request.params as { workflowId: string; gate: string };
    if (!isTtGate(gate)) return reply.code(400).send({ error: "unknown_gate" });
    const parsed = gateApprovalSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    }
    const row = await getWorkflowRequest(pool, workflowId);
    if (!row || row.workflowType !== "triple_threat") return reply.code(404).send({ error: "not_found" });
    if (row.status !== "awaiting_approval") {
      return reply.code(409).send({ error: "not_awaiting_approval", status: row.status });
    }
    const approval: GateApproval = { approvedBy: parsed.data.approvedBy };
    await DBOS.send(workflowId, approval, `gate:${gate}`);
    return reply.code(202).send({ workflowId, gate, status: "approval_sent" });
  });

  // One Stage 8 remediation pass, started by a human click. Only valid while
  // the run waits at finalize-validated-runbook with a non-PASS verdict and
  // passes left. The workflow itself re-checks and runs Stage 7 then Stage 8.
  app.post("/tt-workflows/:workflowId/remediate", async (request, reply) => {
    const { workflowId } = request.params as { workflowId: string };
    const parsed = gateApprovalSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    }
    const row = await getWorkflowRequest(pool, workflowId);
    if (!row || row.workflowType !== "triple_threat") return reply.code(404).send({ error: "not_found" });
    if (row.status !== "awaiting_approval") return reply.code(409).send({ error: "not_awaiting_approval", status: row.status });
    const gate = await getLatestPendingGate(pool, workflowId);
    if (gate !== "finalize-validated-runbook") return reply.code(409).send({ error: "not_at_validation_gate", gate });
    const validationJob = await getLatestTtStageJob(pool, workflowId, "validation");
    const verdict = validationJob?.content ? parseValidationVerdict(validationJob.content) : null;
    if (!verdict) return reply.code(409).send({ error: "no_validation_verdict" });
    if (verdict === "PASS") return reply.code(409).send({ error: "validation_passed" });
    const used = (await listWorkflowEvents(pool, workflowId)).filter((e) => e.eventType === "remediation_started").length;
    if (used >= TT_MAX_REMEDIATION_PASSES) {
      return reply.code(409).send({ error: "remediation_limit_reached", used, max: TT_MAX_REMEDIATION_PASSES });
    }
    const message: GateApproval = { approvedBy: parsed.data.approvedBy, action: "remediate" };
    await DBOS.send(workflowId, message, "gate:finalize-validated-runbook");
    return reply.code(202).send({ workflowId, status: "remediation_requested", pass: used + 1, max: TT_MAX_REMEDIATION_PASSES });
  });

  app.get("/tt-workflows/:workflowId/blockers", async (request, reply) => {
    const { workflowId } = request.params as { workflowId: string };
    const blockers = await listTtBlockers(pool, workflowId);
    return reply.send({ blockers });
  });

  app.post("/tt-workflows/:workflowId/blockers", async (request, reply) => {
    const { workflowId } = request.params as { workflowId: string };
    const parsed = createBlockerSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    }
    const row = await getWorkflowRequest(pool, workflowId);
    if (!row || row.workflowType !== "triple_threat") return reply.code(404).send({ error: "not_found" });
    const blockerId = await nextTtBlockerId(pool, workflowId);
    const blocker = await upsertTtBlocker(pool, {
      workflowId,
      blockerId,
      title: parsed.data.title,
      question: parsed.data.question,
      whyItBlocks: parsed.data.whyItBlocks,
      recommendation: parsed.data.recommendation,
      evidenceRequired: parsed.data.evidenceRequired ?? true
    });
    return reply.code(201).send({ blocker });
  });

  app.post("/tt-workflows/:workflowId/blockers/:blockerId/decision", async (request, reply) => {
    const { workflowId, blockerId } = request.params as { workflowId: string; blockerId: string };
    const parsed = decisionSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    }
    const [existing] = (await listTtBlockers(pool, workflowId)).filter((b) => b.blockerId === blockerId);
    if (!existing) return reply.code(404).send({ error: "not_found" });
    const blocker = await upsertTtBlocker(pool, {
      workflowId,
      blockerId,
      title: existing.title,
      status: "resolved",
      decision: parsed.data.decision,
      evidence: parsed.data.evidence ?? null
    });
    await fileBlockerToMemory(workflowId, blocker);
    return reply.send({ blocker });
  });

  app.post("/tt-workflows/:workflowId/blockers/:blockerId/verify", async (request, reply) => {
    const { workflowId, blockerId } = request.params as { workflowId: string; blockerId: string };
    const [existing] = (await listTtBlockers(pool, workflowId)).filter((b) => b.blockerId === blockerId);
    if (!existing) return reply.code(404).send({ error: "not_found" });
    if (existing.status !== "resolved") return reply.code(409).send({ error: "not_resolved" });
    if (existing.evidenceRequired && !existing.evidence) return reply.code(409).send({ error: "evidence_required" });

    let triliumNoteId = existing.triliumNoteId;
    if (!triliumNoteId) {
      const row = await getWorkflowRequest(pool, workflowId);
      const parentNoteId = (row?.params as { triliumParentNoteId?: string } | undefined)?.triliumParentNoteId;
      if (parentNoteId) {
        const markdownBody = [
          `**Question:** ${existing.question ?? "(none recorded)"}`,
          `**Why it blocks:** ${existing.whyItBlocks ?? "(none recorded)"}`,
          `**Recommendation:** ${existing.recommendation ?? "(none recorded)"}`,
          "",
          `**Decision:** ${existing.decision ?? ""}`,
          `**Evidence:** ${existing.evidence ?? "(none)"}`
        ].join("\n");
        triliumNoteId = await tryCreateTriliumNote(parentNoteId, `${blockerId} — ${existing.title}`, markdownBody);
      }
    }

    const blocker = await upsertTtBlocker(pool, {
      workflowId,
      blockerId,
      title: existing.title,
      verified: true,
      triliumNoteId
    });
    await fileBlockerToMemory(workflowId, blocker);
    return reply.send({ blocker });
  });

  app.get("/tt-workflows/:workflowId/warnings", async (request, reply) => {
    const { workflowId } = request.params as { workflowId: string };
    const warnings = await listTtWarnings(pool, workflowId);
    return reply.send({ warnings });
  });

  app.post("/tt-workflows/:workflowId/warnings", async (request, reply) => {
    const { workflowId } = request.params as { workflowId: string };
    const parsed = createWarningSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    }
    const row = await getWorkflowRequest(pool, workflowId);
    if (!row || row.workflowType !== "triple_threat") return reply.code(404).send({ error: "not_found" });
    const warningId = await nextTtWarningId(pool, workflowId);
    const warning = await upsertTtWarning(pool, { workflowId, warningId, description: parsed.data.description });
    return reply.code(201).send({ warning });
  });

  app.post("/tt-workflows/:workflowId/warnings/:warningId/resolution", async (request, reply) => {
    const { workflowId, warningId } = request.params as { workflowId: string; warningId: string };
    const parsed = resolutionSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    }
    const [existing] = (await listTtWarnings(pool, workflowId)).filter((w) => w.warningId === warningId);
    if (!existing) return reply.code(404).send({ error: "not_found" });
    const warning = await upsertTtWarning(pool, {
      workflowId,
      warningId,
      description: existing.description,
      status: "resolved",
      resolution: parsed.data.resolution,
      evidence: parsed.data.evidence ?? null
    });
    await fileWarningToMemory(workflowId, warning);
    return reply.send({ warning });
  });

  app.post("/tt-workflows/:workflowId/warnings/:warningId/verify", async (request, reply) => {
    const { workflowId, warningId } = request.params as { workflowId: string; warningId: string };
    const [existing] = (await listTtWarnings(pool, workflowId)).filter((w) => w.warningId === warningId);
    if (!existing) return reply.code(404).send({ error: "not_found" });
    if (existing.status !== "resolved") return reply.code(409).send({ error: "not_resolved" });

    let triliumNoteId = existing.triliumNoteId;
    if (!triliumNoteId) {
      const row = await getWorkflowRequest(pool, workflowId);
      const parentNoteId = (row?.params as { triliumParentNoteId?: string } | undefined)?.triliumParentNoteId;
      if (parentNoteId) {
        const markdownBody = [
          `**Warning:** ${existing.description}`,
          "",
          `**Resolution:** ${existing.resolution ?? ""}`,
          `**Evidence:** ${existing.evidence ?? "(none)"}`
        ].join("\n");
        triliumNoteId = await tryCreateTriliumNote(parentNoteId, `${warningId} — ${existing.description}`, markdownBody);
      }
    }

    const warning = await upsertTtWarning(pool, {
      workflowId,
      warningId,
      description: existing.description,
      verified: true,
      triliumNoteId
    });
    await fileWarningToMemory(workflowId, warning);
    return reply.send({ warning });
  });
}
