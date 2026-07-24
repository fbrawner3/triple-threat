# Triple Threat

Status: active
Created: 2026-07-12
Owner: Felton
Builder: Codex / Claude / Antigravity (multi-agent orchestration)

## Purpose

An AI-assisted development workflow that sequences three coding agents (Claude, Codex, and an "agy" agent) through an eight-stage pipeline — planning, architecture, build, review, adjudication, decision register, implementation, and validation — stopping at defined approval gates instead of running unattended end-to-end.

The orchestrator resolves a project name to a working directory and a slug, then drives each stage through the appropriate agent via a Windows PowerShell runner, recording state so a run can be resumed at a specific gate rather than restarted from scratch.

## Structure

```
orchestrator/       Stage sequencing runner (run.ps1) and stage-set migrations
plugins/            Plugin definition wired into the host agent runtime
runtime-skill/       Skill definition consumed by the agent runtime at execution time
tests/              Isolated/fake-agent test harnesses for the cutover, desktop-shortcut, and e2e paths
activate.ps1        Installs the orchestrator + plugin into a local agent runtime install
enable-desktop.ps1  Adds a desktop-launchable shortcut for the orchestrator
```

## Stack

- PowerShell (orchestration, stage runner, install/activation scripts)
- Python (plugin runtime hook)
- Three independent AI coding agents as pipeline stage executors

## Notes

This is a personal workflow tool, published for portfolio purposes. The scripts were extracted from a larger private monorepo where they lived under a nested `hermes/` directory tree — path references inside `activate.ps1`, `enable-desktop.ps1`, and the orchestrator scripts still assume that original nested layout and have **not** been rewritten for this flattened, standalone structure. Treat this as a reference implementation of the orchestration design, not a drop-in installable tool.
