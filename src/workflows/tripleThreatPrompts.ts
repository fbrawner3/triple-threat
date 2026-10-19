// Stage prompt templates for the DBOS Triple-Threat workflow. The agent-runner
// service owns agent invocation, so these prompts carry only the stage
// contract and its behavioral boundaries.
import { z } from "zod";
import { OBSIDIAN_DOC_STYLE } from "../obsidianStyle.js";
import type { TtSpecialist, TtStage } from "../types.js";

export interface StageContext {
  projectName: string;
  projectSlug: string;
  projectDir: string;
  round: number;
  // Launch-time project source text (see TripleThreatRequest.sourceContent).
  sourceContent?: string;
  // Prior-stage artifact text, keyed by stage, so later stages can see
  // earlier output without re-deriving it.
  priorArtifacts: Partial<Record<TtStage, string>>;
  // Rendered separately because it can be large/dynamic: the finalized
  // blocker manifest (stage 6) or the open validation warnings (loop after
  // stage 8) — not always "the previous stage's artifact".
  extra?: string;
  // Set only on a Stage 8 remediation pass: the validation failures and open
  // warnings Stage 7 must fix (see buildRemediationBlock).
  remediation?: string;
}

// The Stage 7 re-run's brief. Same guardrails that Gauntlet's reviser needed
// after it deleted and restructured files: fix what the findings name, nothing
// else, and write real values instead of hedging.
export function buildRemediationBlock(params: {
  pass: number;
  maxPasses: number;
  verdict: string;
  validationReport: string;
  openWarnings: string[];
}): string {
  const warnings = params.openWarnings.length ? params.openWarnings.map((w) => `- ${w}`).join("\n") : "(none open)";
  return `\n\nREMEDIATION PASS ${params.pass} of ${params.maxPasses}. Stage 8 validation of your previous implementation returned ${params.verdict}. Fix the package so each required fix below is actually resolved in the files.

Rules for this pass:
- Edit files in place inside ${"${projectDir}"}. Do NOT delete, rename, merge, or split any file, and do NOT change how the package is divided; the existing structure stands.
- Change only what the findings name. Do not redesign, and do not undo anything in the Decision Register.
- Write real content and concrete values. Adding a note, a "verification gate", a TODO, or an "[UNVERIFIED]" marker does not fix a finding. If a finding truly cannot be fixed from the files and decisions available, leave it and say exactly why in your reply.
- Update INSTALLATION-GUIDE.md wherever a fix changes a step. Keep its numbering and format.

## Stage 8 validation report (the findings to fix)

${params.validationReport}

## Open validation warnings

${warnings}
`;
}

// Replaces the old triliumInstruction() (removed 2026-09-21, Felton's call:
// TT moves off the Trilium exception onto vector memory like everything else
// in migrated scope). The agent has mcp__geekygramps__write_memory available
// (see agent-runner-service's --allowedTools) and gets a fully-formed
// note_id/project/doc_type from us instead of having to search-and-guess a
// Trilium note tree -- write_memory upserts on note_id, so a replay or a
// deliberate re-run of the same stage/round just updates the existing note
// instead of creating a duplicate.
function vectorMemoryInstruction(ctx: StageContext, stage: TtStage, noteTitle: string, docType: string, subfolder?: string): string {
  const noteId = `tt-${ctx.projectSlug}-r${ctx.round}-${stage}`;
  const ancestry = subfolder
    ? [ctx.projectName, `Round ${ctx.round}`, subfolder]
    : [ctx.projectName, `Round ${ctx.round}`];
  return `\n\nFile this stage's output yourself: call mcp__geekygramps__write_memory with note_id="${noteId}", title="${noteTitle}", project="${ctx.projectSlug}", doc_type="${docType}", ancestry=${JSON.stringify(ancestry)}, content set to this stage's full output. Reuse that exact note_id every time so a re-run updates the note instead of duplicating it.\n\nAfter filing, your final reply must be this stage's complete output, exactly as you filed it (including any fenced json block the stage asks for) -- not a summary, not a confirmation, not a pointer to the filed note. The workflow parses your reply and hands it to the next stage; a summary starves both.`;
}

// The implementation stage additionally files the INSTALLATION-GUIDE.md
// content on its own under doc_type "tt_final_runbook" -- the one doc_type
// (besides gauntlet_consolidated_verdict) the vector store auto-flags
// to_obsidian=true for, per db/migrations/202609070001_vector_memory.sql.
// Keep this separate from the general "tt_implementation" stage-output note:
// that one mixes in the code-change summary, which isn't runbook content.
function runbookVectorMemoryInstruction(ctx: StageContext): string {
  // Human-facing name is "Installation Guide"; the doc_type stays
  // tt_final_runbook because the DB CHECK constraint and ingest.js key the
  // Obsidian export off that exact value.
  const noteId = `tt-${ctx.projectSlug}-r${ctx.round}-installation-guide`;
  return `\n\nSeparately, file INSTALLATION-GUIDE.md's own content on its own: call mcp__geekygramps__write_memory with note_id="${noteId}", title="${ctx.projectName} — Installation Guide", project="${ctx.projectSlug}", doc_type="tt_final_runbook", ancestry=${JSON.stringify([ctx.projectName, `Round ${ctx.round}`])}, content set to the exact INSTALLATION-GUIDE.md content (not your summary of it). Reuse that exact note_id on a re-run.`;
}

export interface StageDefinition {
  specialist: TtSpecialist;
  mode: "write" | "readonly";
  buildPrompt(ctx: StageContext): string;
}

const COMMON_BOUNDARIES = `Boundaries that apply to every stage: never deploy, install, apply, commit, push, or change live infrastructure. Never grant yourself broader sandbox/permission access than you were invoked with. Do not modify files outside ${"${projectDir}"} unless a stage explicitly says otherwise. If required evidence is unavailable, say so explicitly rather than inventing it.`;

function header(ctx: StageContext, stageLabel: string): string {
  return `Triple-Threat round ${ctx.round} for project "${ctx.projectName}" (slug: ${ctx.projectSlug}, directory: ${ctx.projectDir}). Stage: ${stageLabel}.\n\n${COMMON_BOUNDARIES}\n`;
}

function priorArtifact(ctx: StageContext, stage: TtStage, label: string): string {
  const content = ctx.priorArtifacts[stage];
  return content ? `\n## ${label}\n\n${content}\n` : "";
}

export const STAGE_DEFINITIONS: Record<TtStage, StageDefinition> = {
  design: {
    specialist: "claude",
    mode: "write",
    buildPrompt: (ctx) =>
      `${header(ctx, "Project Design")}${ctx.sourceContent ? `The project's source material follows. It was supplied at launch; do not look for it on disk.\n\n## Project Source\n\n${ctx.sourceContent}\n\n` : "Read every top-level file in the project directory. "}Begin with a "Source deliverables" checklist: extract, verbatim, every explicit task, step, and deliverable the source asks for. Never split any of them off, defer them, or move them to a separate track without Felton's decision. If an item needs research (web lookups, checking registries, reading upstream repos or docs), you MUST do it yourself now with WebSearch and WebFetch and record the answer with the source URLs; the user does not have this information and is relying on you to find it. Only mark an item OPEN if a tool call actually fails, and then quote the exact error. Never mark it OPEN because you did not try. Later stages are checked against this checklist. Then produce a project design covering: problem statement, goals, non-goals, stakeholders, and phases. This is a design document, not code — do not write or modify project source files at this stage.${vectorMemoryInstruction(ctx, "design", "Project Design", "tt_design")}`
  },
  architecture: {
    specialist: "claude",
    mode: "write",
    buildPrompt: (ctx) =>
      `${header(ctx, "Architecture")}${priorArtifact(ctx, "design", "Project Design (from Stage 1)")}Address every item in the Project Design's "Source deliverables" checklist; none may be dropped. Produce the architecture: goals, assumptions, constraints, a diagram, dependencies, risks, rollback strategy, implementation phases, definition of ready, definition of done, final deliverables, and the explicit activation/go-live boundary. This is a design document — do not write or modify project source files at this stage.${vectorMemoryInstruction(ctx, "architecture", "Architecture Summary", "tt_architecture")}`
  },
  codex_review: {
    specialist: "codex",
    mode: "write",
    buildPrompt: (ctx) =>
      `${header(ctx, "Codex Implementation Review")}${priorArtifact(ctx, "architecture", "Architecture (from Stage 2)")}Review the architecture above and the current state of the project directory for deployability, configuration, dependencies, operations, security, migration, data loss, backup, and restore. Do not redesign or modify project files at this stage — this is a review only. Write your review as a single markdown artifact; do not touch any file outside your own output.${vectorMemoryInstruction(ctx, "codex_review", "Codex Implementation Review", "tt_codex_review", "Reviews")}`
  },
  antigravity_review: {
    specialist: "antigravity",
    mode: "readonly",
    buildPrompt: (ctx) =>
      `${header(ctx, "Antigravity Architecture Review")}${priorArtifact(ctx, "architecture", "Architecture (from Stage 2)")}Independently review the architecture above for architectural risk, scalability, high-availability assumptions, failure domains, complexity, operational burden, maintainability, and long-term skill requirements. Read-only regarding the project: do not modify project files or propose implementation work.${vectorMemoryInstruction(ctx, "antigravity_review", "Antigravity Architecture Review", "tt_antigravity_review", "Reviews")}`
  },
  adjudication: {
    specialist: "claude",
    mode: "write",
    buildPrompt: (ctx) =>
      `${header(ctx, "Adjudication")}${priorArtifact(ctx, "codex_review", "Codex Implementation Review (Stage 3)")}${priorArtifact(ctx, "antigravity_review", "Antigravity Architecture Review (Stage 4)")}Account for every finding from both reviews above. Record agreements and disagreements explicitly. Produce a blocker manifest: each blocker needs a stable ID (B1, B2, ...), a title, the question it raises, why it blocks, a recommendation, alternatives considered, consequences, and whether evidence is required to close it. Before you list anything as a blocker, test it: if the answer is a fact you can find yourself (web lookups with WebSearch/WebFetch, searching or reading the repository, read-only inspection of files), go find it now and record the answer with its source under a "Resolved by research" section instead of listing it as a blocker. Only list as a blocker what needs a decision from Felton, or evidence you genuinely cannot reach (live browser behavior, private systems, credentials); for each of those, state exactly why you could not resolve it yourself. Never make Felton's decisions for him.\n\nAfter the prose manifest, append one fenced json block — exactly this shape and nothing else inside the fence — so the workshop can be seeded automatically:\n\`\`\`json\n[{"id": "B1", "title": "...", "question": "...", "whyItBlocks": "...", "recommendation": "...", "evidenceRequired": true}]\n\`\`\`\nOne object per blocker, same IDs and wording as the prose above, \`evidenceRequired\` a boolean (true unless the blocker is a pure decision that needs no evidence to close).${vectorMemoryInstruction(ctx, "adjudication", "Adjudication", "tt_adjudication")}`
  },
  decision_register: {
    specialist: "claude",
    mode: "write",
    buildPrompt: (ctx) =>
      `${header(ctx, "Decision Register")}${priorArtifact(ctx, "adjudication", "Adjudication (Stage 5)")}${ctx.extra ? `\n## Finalized Blocker Manifest\n\n${ctx.extra}\n` : ""}Produce the decision register: include only adjudicated, resolved, and verified workshop decisions and their recorded evidence. If the blocker manifest above is not fully finalized, stop and say so rather than producing a partial register.${vectorMemoryInstruction(ctx, "decision_register", "Decision Register", "tt_decision_register")}`
  },
  implementation: {
    specialist: "codex",
    mode: "write",
    buildPrompt: (ctx) =>
      `${header(ctx, "Implementation")}${priorArtifact(ctx, "decision_register", "Decision Register (Stage 6)")}${ctx.remediation ? ctx.remediation.replaceAll("${projectDir}", ctx.projectDir) : ""}Produce every item in the Project Design's "Source deliverables" checklist that the decision register has not explicitly cancelled. Write only approved executable/deployable source, configuration, manifests, migrations, and installation assets inside ${ctx.projectDir}, plus an INSTALLATION-GUIDE.md: a complete, human-readable installation guide that doubles as documentation. It must cover prerequisites, install, configure, enable, validate, operate, recover, rollback, unresolved blockers, and the explicit manual go-live boundary, written as numbered steps an operator can follow, with exact commands wherever the facts are verified (from the repository, the project docs, or the decision register). Before concluding anything is unknown, search the enclosing repository for the real source, config, and deploy files, and cite the file paths you found. Run a resource-lifecycle and command-order audit before finalizing the guide: every referenced database, role, grant, schema, auth rule, secret, CRD, namespace, service, file, and tool must be verified as existing or created by an earlier exact step in the guide. Never invent live facts. Where authoritative evidence for a step is unavailable, do not drop the step: write it out with the best-supported command and mark it inline as **[UNVERIFIED: what must be confirmed first]**, and put a "Verified vs. unverified" table at the top of the guide. Never run, deploy, install, apply, commit, or push the result yourself.\n\nFormat INSTALLATION-GUIDE.md (and only that file) this way. ${OBSIDIAN_DOC_STYLE}${vectorMemoryInstruction(ctx, "implementation", "Implementation Summary", "tt_implementation")}${runbookVectorMemoryInstruction(ctx)}`
  },
  validation: {
    specialist: "claude",
    mode: "readonly",
    buildPrompt: (ctx) =>
      `${header(ctx, "Validation")}${priorArtifact(ctx, "implementation", "Implementation summary (Stage 7)")}Read-only validation of the approved design and the implementation package (including INSTALLATION-GUIDE.md) produced in Stage 7. Check that installation, configuration, activation, operations, recovery, rollback, and the manual go-live boundary are all present and correct — any of these missing is an automatic fail. Also check the Project Design's "Source deliverables" checklist item by item: any item neither delivered nor explicitly cancelled in the decision register is a required fix. Finish with exactly one verdict: Pass, Pass With Warnings, or Fail. If Fail, list every required fix as a numbered finding.\n\nAlso append a fenced json block so the verdict can be parsed reliably, exactly this shape and nothing else inside the fence:\n\`\`\`json\n{"verdict": "PASS"}\n\`\`\`\nUse "PASS", "PASS_WITH_WARNINGS", or "FAIL" as the value, matching your prose verdict above.${vectorMemoryInstruction(ctx, "validation", "Validation Report", "tt_validation")}`
  }
};

// Decided 2026-08-28 during the TT Stage 8 gap review: TT is AI-assisted
// human gating, not autonomy -- no auto-remediation loop back to Stage 7.
// The fix scoped down to this: run Stage 8 once, reliably classify its
// verdict, surface it plainly at the gate instead of a wall of prose Felton
// has to read to figure out what happened. Same fenced-json-block technique
// already proven for Gauntlet's findings (gauntlet/findings.ts) -- free text
// alone can't be trusted to parse consistently.
//
// Fail-safe on purpose: a missing/malformed block or a "no output" case
// returns FAIL, never silently treated as clean. Matches gauntletWorkflow's
// own rule that a failed/missing review counts against the verdict, not for it.
export type ValidationVerdict = "PASS" | "PASS_WITH_WARNINGS" | "FAIL";

const validationVerdictSchema = z.object({ verdict: z.enum(["PASS", "PASS_WITH_WARNINGS", "FAIL"]) });

export function parseValidationVerdict(content: string): ValidationVerdict {
  const match = content.match(/```json\s*([\s\S]*?)```/i);
  if (!match) return "FAIL";
  try {
    const parsed: unknown = JSON.parse(match[1].trim());
    const result = validationVerdictSchema.safeParse(parsed);
    return result.success ? result.data.verdict : "FAIL";
  } catch {
    return "FAIL";
  }
}
