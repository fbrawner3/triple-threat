---
name: triple-threat-orchestrator
description: Run or resume Felton's eight-stage triple-threat project workflow and its adjudication blocker workshop through native Claude Code, Codex, and Antigravity. Use when Felton asks to start, run, continue, resume, show status, work or research blockers, record or verify a blocker decision, finalize adjudication, or finalize a runbook for a named project.
---

# Triple-Threat Orchestrator

Run the repository PowerShell orchestrator from the canonical repository root.

Every supported Triple-Threat command Felton issues is final authorization for that command's normal coordinator transaction, runtime-state writes, routine Trilium synchronization, and assigned specialist stage. Execute it without another permission or confirmation prompt. This authorization never extends to deployment, installation, activation, commits, pushes, destructive actions, or an unnamed gate.

## Shorthand

`/tt` is the single entry point for every Triple-Threat command in Hermes Desktop. Treat this as the standard launch command:

```text
/tt Triple threat: <project name>
```

Resolve the remaining values before running:

1. Match `<project name>` to an existing top-level repository project directory.
2. Match it to `Planner/Projects/<project name>` in Trilium.
3. Normalize the project name to a lowercase hyphenated slug.
4. Show the resolved name, slug, repository directory, and Trilium path.
5. If either match is ambiguous or missing, ask Felton rather than creating a location.
6. Otherwise run Stages 1 through 8 and stop at every approval gate.

The matched title is the repository folder name. Before each specialist stage, the wrapper inventories every file directly inside that folder and requires the specialist to read every listed file. Do not include files from subfolders in this automatic inventory; stage-specific artifacts may still be read when explicitly passed to a stage.

## Storage Boundary

Keep the repository limited to executable or deployable project material: source code, configuration, manifests, migrations, installation assets, and the final operator runbook. Do not store planning, architecture, reviews, adjudication, decisions, validation reports, prompts, agent responses, state, or run logs in the project directory.

Store readable project knowledge in Trilium under this structure:

```text
Planner / Projects / <Project>
  Project Documents
  Triple-Threat Pipeline
    Round <n>
      Reviews
        Adjudicated Findings
      Run History
```

Use `Project Documents` for the canonical project overview, design documents, architecture, workflows, contracts, roster, and backlog. Use the current `Round <n>` for that run's design, architecture summary, raw reviews, adjudication, decision register, implementation summary, and validation report. Use `Run History` only for readable run history.

Temporary prompts, raw agent responses, receipts, and resumable state belong in `%LOCALAPPDATA%\hermes\pipelines\<project-slug>`, never in the repository. The orchestrator automatically verifies and moves a legacy repository `.pipeline` directory into that location before resuming it.

## Phase Tracker

Maintain one fixed human-readable checklist for every project in Trilium. Use `Planner / Tasks / Triple-Threat Control Center / Phase Tracker Template` as the content template.

For a new project:

1. Read the template and create a new text note named `<Project> — Phase Tracker` directly under `Planner / Projects / <Project>`. Copy the template content; do not clone the template because project checkboxes must be independent.
2. Clone the new project tracker under `Planner / Tasks / Triple-Threat Control Center / Active Projects` so the same tracker is visible in both locations.
3. Add labels `tripleThreatTracker=true`, `projectSlug=<slug>`, `pipelineStatus=<state>`, `currentStage=<next-stage>`, and `pendingGate=<gate-or-empty>`.
4. Add relations to the command guide and current pipeline round when those notes exist.

After every orchestrator invocation, read the verified runtime state before changing the tracker. Check exactly the stage or gate that actually completed, update the current-state header, and place the exact next conversational command at the top. A failed or interrupted stage changes the status text but never checks its box. An approval checks its gate only when the matching approval exists in runtime state. Never treat the checklist as execution state; it is a synchronized view of the orchestrator state.

When reporting any result to Felton, include the same exact next command shown in the tracker. Never say a project is done while a gate, workshop item, validation, or finalization item remains unchecked.

## Adjudication Blocker Workshop

Stage 5 must stop in `awaiting-workshop`. Entering, viewing, researching, or recording workshop information is read-only with respect to pipeline advancement and requires no gate approval. Never ask Felton to approve a gate before starting the workshop. Never accept `Approve post-adjudication` as a bypass. Translate conversational workshop commands to the same repository orchestrator command and project arguments used for the run:

Use the native `/tt` plugin command for workshop operations. It dispatches directly to the repository wrapper without an LLM interpretation step, accepts blocker IDs and decision text, and selects the single active Triple-Threat project from Hermes local pipeline state. Do not answer by summarizing the Adjudication note, review findings, checklist, or model memory. Only the enforced blocker manifest returned by the wrapper defines the workshop inventory and status. If the wrapper was not invoked successfully, do not claim the workshop started and never suggest `Approve post-adjudication`.

| Felton says | Additional arguments |
|---|---|
| `/tt work` | `-WorkshopAction work` |
| `/tt show` | `-WorkshopAction show` |
| `/tt open <ID>` | `-WorkshopAction open -BlockerId <ID>` |
| `/tt research <ID>` | `-WorkshopAction research -BlockerId <ID>` |
| `/tt brief <ID>` | `-WorkshopAction brief -BlockerId <ID>` |
| `/tt resume <ID>` | `-WorkshopAction resume -BlockerId <ID>` |
| `/tt create <title>` | `-WorkshopAction create -BlockerTitle <title>`; create the blocker immediately, then collect its definition |
| Felton supplies Question, Why it blocks, Recommendation, alternatives, and evidence requirement | `-WorkshopAction define -BlockerId <ID>` with the supplied structured fields |
| `/tt record <ID> <text>` | `-WorkshopAction record -BlockerId <ID> -Decision <text>` |
| `/tt record <ID> <text> --evidence <text>` | add `-Evidence <text>` |
| `/tt verify <ID>` | `-WorkshopAction verify -BlockerId <ID>` |
| `/tt paste <PATH>` | Read a long command saved by Hermes under its local `pastes` directory and dispatch it exactly as entered. |
| `/tt finalize adjudication` | `-WorkshopAction finalize` and then Stage 6 |

The orchestrator JSON manifest is the enforcement source. Mirror each successful workshop change into the matching Trilium note under `Triple-Threat Pipeline / Round <n> / Blocker Workshop`, the current round's canonical `Adjudication` note, and the project phase tracker. In `Adjudication`, regenerate the top status, Blocker Register, progress, next unresolved blocker, and Felton decision status from the manifest while preserving the adjudication narrative and reviewer findings. Update each blocker note's native `status` and `verified` labels. Never mark a Trilium blocker resolved unless the wrapper successfully verifies it. Never put secret values in decision or evidence fields. The wrapper's reported blocker count is authoritative; do not combine separate blocker IDs or promote non-blocking implementation actions into the workshop inventory.

When Hermes replaces a long pasted `/tt` command with a line such as `[Pasted text ... -> C:\\...\\hermes\\pastes\\paste_....txt]`, run `/tt paste <that path>`. The plugin reads only from Hermes' own local `pastes` directory, does not delete the saved paste, and processes the full original command without shortening its decision or evidence.

`Finalize adjudication` is Felton's explicit approval of all resolved decisions. It must fail while any blocker is not both `resolved` and `verified`. On success it records the post-adjudication approval and runs Stage 6, which creates the Decision Register and then pauses at the next gate. It deploys nothing.

A title-only create command creates and synchronizes the blocker first, then asks for Question, Why it blocks, Recommendation, and whether evidence is required. Felton's conversational answer updates that existing blocker through `define`; do not create a second blocker or fill it with generic placeholder text.

## Transaction Receipts

For every mutating command—run/resume, work, research, create, define, record, verify, finalize, validation remediation, or gate approval—generate one GUID and pass it as `-TransactionId`. Invoke the wrapper exactly once. After it returns, re-read `state.json` and require `lastTransaction.id` to match the caller GUID before synchronizing Trilium or reporting success. For workshop changes, also require the saved manifest SHA-256 to match the receipt.

A command timeout is not proof of failure. Do not retry a mutation after a timeout. Re-read saved state using the original GUID and continue monitoring the original process. Never infer a permission error when the wrapper did not return one.

Example:

```text
Triple threat: AI IT Agents
```

Resolves to project `AI IT Agents`, slug `ai-it-agents`, directory `AI IT Agents`, and Trilium path `Planner/Projects/AI IT Agents`.

For a new run, collect project name, slug, repo-relative project directory, Trilium project path, and stage range. Never infer a destructive action or bypass an approval gate.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File hermes/skills/triple-threat-orchestrator/run.ps1 -Project "<name>" -ProjectSlug "<slug>" -ProjectDir "<repo-relative-dir>" -TriliumProjectPath "<trilium-path>" -FromStage 1 -ToStage 8
```

When the script reports an ordinary approval gate, show the gate and stop. This applies to `post-architecture`, `post-decision-register`, `post-implementation`, and the final `post-validation` handoff. It never applies to `post-adjudication`, which can advance only through `Finalize adjudication` after the workshop. Resume an ordinary gate only after Felton explicitly approves:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File hermes/skills/triple-threat-orchestrator/run.ps1 -Project "<name>" -ProjectSlug "<slug>" -ProjectDir "<repo-relative-dir>" -TriliumProjectPath "<trilium-path>" -FromStage 1 -ToStage 8 -ApproveGate <gate>
```

An ordinary approval gate is a pause, not completion. Never describe a run with `status: awaiting-approval` as finished or done. Always show the pending gate, next stage, and exact continuation command. If state is `awaiting-workshop` or the gate is `post-adjudication`, never emit an approval instruction; invoke or resume the workshop instead.

After Stage 8 ends with `Pass` or `Pass With Warnings`, stop at `post-validation`. `Finalize validated runbook` passes `-ApproveGate post-validation`, accepts the final handoff, and marks the workflow complete without deploying or activating anything.

When Stage 8 ends with `Pass With Warnings`, the wrapper creates `validation-warnings-round-<n>.json` from the open W-numbered rows in the report. Warning follow-up does not reopen stages or gates and never invokes a specialist:

* `/tt warnings` shows warning progress.
* `/tt reconcile warnings` repairs a legacy warning manifest against the open/resolved statuses in the Stage 8 report, preserving valid recorded work.
* `/tt open W3` shows one warning.
* `/tt record W3 <resolution> --evidence <evidence>` records a proposed resolution.
* `/tt verify W3` verifies a recorded resolution and its evidence.

Every warning record, verification, and reconciliation updates the canonical Trilium Validation Report's current Warnings Summary, the individual warning notes, the project phase tracker, and `Validation Warnings — Live Tracker`. The original Stage 8 narrative remains clearly labeled as historical validation context.

The `/tt` plugin synchronizes warning notes under `Triple-Threat Pipeline / Round <n> / Validation Warnings` and regenerates the project phase tracker from saved runtime state after every successful command. Internal `currentStage=9` means “past Stage 8”; never display it as a ninth phase.

When Stage 8 ends with `Fail`, no gate is pending. Report the blocking validation findings and the exact next command `/tt Remediate validation for <Project>`. That explicit command passes `-RemediateValidation` plus a transaction GUID, returns the workflow to Stage 7, rebuilds only the approved implementation and runbook, then pauses again at `post-implementation` before re-validation. Never silently rerun Stage 7 or Stage 8.

For a stage preflight, use `-PreflightOnly`. It validates the saved stage, required artifacts, architecture fallback, finalized blocker manifest, and assigned specialist executable without invoking an agent or changing state.

For installation validation, use the same command with `-ValidateOnly`. This freshly parses every Hermes PowerShell script, checks that the project directory remains inside the repository, and executes only non-agent help/version surfaces for `codex`, `claude`, and `agy`. It must not invoke an agent, create repository `.pipeline`, create runtime state, or write to Trilium.

For `AI IT Agents`, use directory `AI IT Agents`, slug `ai-it-agents`, Trilium path `Planner/Projects/AI IT Agents`, and canonical Trilium note ID `EWSagIc6T5iH`.

Never deploy, install infrastructure, commit, or push. Never manually delete pipeline state; allow the orchestrator's verified legacy-state migration.

## Plain-English Progress

Felton wants human-readable status, never raw tool telemetry.

Before starting any long-running command, send one short conversational update describing the real activity, for example:

* `Reading the project files.`
* `Running Stage 5 adjudication with Claude.`
* `Saving and checking the review.`

Do not expose shell commands, tool names, process IDs, polling, waits, JSON events, file-search operations, or code-style execution traces unless Felton explicitly asks for diagnostic details. Do not stay completely silent: announce the current stage before starting it, then report its result, failure, or approval gate in plain English when it returns. The `/tt` plugin must print the final result automatically when a background workflow finishes; Felton must never need to guess or poll for completion. `/tt status` must report stage progress, saved status, pending gate, failure, and the exact next command rather than only listing blockers. Keep each update to one sentence.

Use `/tt test feedback` after installing or updating the plugin to prove asynchronous completion output without changing workflow state or invoking a specialist.
