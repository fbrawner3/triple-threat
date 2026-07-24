# Hermes Skill: triple-threat-orchestrator

Sequences the eight Triple-Threat stages for a named project and stops at every approval gate.

## Trigger and Resolution

`/tt Triple threat: <project name>` resolves the name to an existing top-level repository directory, a lowercase hyphenated slug, and `Planner/Projects/<project name>` in Trilium. The automatic project inventory contains every file directly inside the project directory and excludes subfolders.

## Native Windows Command

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File hermes/skills/triple-threat-orchestrator/run.ps1 -Project "<name>" -ProjectSlug "<slug>" -ProjectDir "<repo-relative-directory>" -TriliumProjectPath "Planner/Projects/<name>" -FromStage 1 -ToStage 8
```

Resume a pending gate by adding `-ApproveGate <gate>`. Validation adds `-ValidateOnly`; it parses all five scripts, validates the repository-contained project path, and confirms `codex`, `claude`, and `agy` without invoking an agent or creating storage.

## State and Artifacts

Machine state, prompts, raw responses, handoffs, receipts, and local logs live at `%LOCALAPPDATA%\hermes\pipelines\<project-slug>`. A legacy `<project>/.pipeline` is copied, verified file-by-file with SHA-256, and removed before the run resumes.

Readable content lives in Trilium:

```text
Planner / Projects / <Project>
  Project Documents
  Triple-Threat Pipeline
    Round <n>
      Reviews
        Adjudicated Findings
      Run History
```

The repository receives only approved Stage 7 executable/deployable files and `IMPLEMENTATION-RUNBOOK.md`.

## Trilium Phase Tracker

At project creation, copy the fixed `Planner / Tasks / Triple-Threat Control Center / Phase Tracker Template` into the project's main Trilium folder as `<Project> — Phase Tracker`, then clone that project tracker into the Control Center's `Active Projects` book. Never clone the template itself.

After every verified stage or gate transition, check the one matching item and update the tracker header with current state, pending gate, and the exact next conversational command. Failures do not check boxes. Runtime state enforces the workflow; the tracker is the synchronized human-readable view.

## Approval Gates

- `post-architecture` after Stage 2
- `post-adjudication` after Stage 5
- `post-decision-register` after Stage 6
- `post-implementation` after Stage 7
- `post-validation` after a passing Stage 8 validation

Approval advances planning or file generation only. It never deploys, installs, applies, commits, pushes, or activates anything.

An approval gate is a paused workflow, never a completed workflow. Hermes must report the pending gate, the next stage, `When ready, use command: "Approve <gate>" to continue.`, and the exact continuation command emitted by the wrapper.

After Stage 5 the workflow uses `awaiting-workshop`, not ordinary approval. Direct `/tt approve post-adjudication` is rejected. Use `/tt work`, `/tt show`, `/tt open <ID>`, `/tt research <ID>`, `/tt brief <ID>`, `/tt resume <ID>`, `/tt record <ID> <decision>`, `/tt verify <ID>`, and `/tt finalize adjudication`. Finalization succeeds only when every blocker is resolved and verified, then records approval and starts Stage 6.

Every workshop display or successful mutation synchronizes the runtime blocker manifest into the current round's canonical `Adjudication` note, `Blocker Workshop` notes, and project phase tracker. The `Adjudication` note's top status, Blocker Register, progress, next unresolved blocker, and Felton decision status must reflect the manifest without replacing its narrative or reviewer findings.

New blockers discovered during the workshop use `/tt create <title>`, followed by structured definition of Question, Why it blocks, Recommendation, alternatives, and evidence requirement. Mutating actions use caller-generated transaction GUIDs and idempotent receipts.

A passing Stage 8 stops at `post-validation` for `/tt finalize validated runbook` or `/tt approve post-validation`. A failing Stage 8 has no pending gate and requires `/tt Remediate validation for <Project>` back through Stage 7 before re-validation. Neither path deploys or activates anything.

For `Pass With Warnings`, use `/tt warnings`, `/tt reconcile warnings` when repairing a legacy import, `/tt open W3`, `/tt record W3 <resolution> --evidence <evidence>`, and `/tt verify W3`. Warning follow-up persists separately from the completed eight-stage run, invokes no agent, and deploys nothing. Every successful warning mutation synchronizes the canonical Trilium Validation Report's current Warnings Summary, individual warning notes, `Validation Warnings — Live Tracker`, and the phase tracker. The original Stage 8 narrative remains clearly labeled as historical validation context. Internal `currentStage=9` is a completion sentinel, not a ninth phase.

## Acceptance

- No gate advances without the matching recorded approval.
- Resume starts from recorded state and does not rerun completed stages.
- Failures stop the workflow and preserve the reason.
- `-ValidateOnly` creates neither repository `.pipeline` nor local runtime state.
- The plugin automatically prints completion or failure for background work; `/tt status` reports all eight stages, the pending gate or failure, and the exact next command.
- Failed validation cannot be approved; it must pass through the controlled Stage 7 remediation loop.
