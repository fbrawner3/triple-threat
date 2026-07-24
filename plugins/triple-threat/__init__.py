"""Hermes slash-command adapter for the FNDHome Triple-Threat workshop."""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


ACTIVE_STATUSES = {"ready", "awaiting-workshop", "awaiting-approval", "failed", "running"}
WORKSHOP_ACTIONS = {"work", "show", "open", "research", "brief", "resume", "create", "record", "verify"}
ID_ACTIONS = {"open", "research", "brief", "resume", "record", "verify"}
MUTATING_ACTIONS = {"work", "research", "create", "record", "verify"}
MAX_PASTE_BYTES = 128 * 1024
HELP = """Triple-Threat commands:
/tt Triple threat: <project name>
/tt status
/tt test feedback
/tt continue
/tt resume Stage 7
/tt approve post-architecture
/tt finalize adjudication
/tt warnings
/tt reconcile warnings
/tt open W3
/tt record W3 <resolution> --evidence <evidence>
/tt verify W3
/tt Remediate validation for <project name>
/tt work
/tt show
/tt open B1
/tt research B1
/tt brief B1
/tt resume B1
/tt create <blocker title>
/tt record B1 <decision>
/tt record B1 <decision> --evidence <evidence>
/tt verify B1
/tt paste <Hermes paste-file path>

`/tt` is the single entry point for the complete Triple-Threat workflow. It
never deploys, installs, commits, pushes, or activates infrastructure."""

TRILIUM_MCP_URL = os.environ.get("TRILIUM_MCP_URL", "http://localhost:37840/mcp")


def _hermes_home() -> Path:
    configured = os.environ.get("HERMES_HOME")
    if configured:
        return Path(configured).expanduser()
    local = os.environ.get("LOCALAPPDATA")
    if os.name == "nt" and local:
        return Path(local) / "hermes"
    return Path.home() / ".hermes"


def _repo_root() -> Path:
    configured = os.environ.get("FNDHOME_REPO")
    candidates = []
    if configured:
        candidates.append(Path(configured))
    candidates.extend(
        [
            Path(r"C:\homelab_git\Gittea\Feltons-HomeLab"),
            Path.cwd(),
        ]
    )
    for candidate in candidates:
        resolved = candidate.expanduser().resolve()
        if (resolved / "hermes" / "skills" / "triple-threat-orchestrator" / "run.ps1").is_file():
            return resolved
    raise RuntimeError("FNDHome repository was not found. Set FNDHOME_REPO to its full path.")


def _read_state(path: Path) -> dict | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _mcp_tool(name: str, arguments: dict) -> object:
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": "tools/call", "params": {"name": name, "arguments": arguments}}
    ).encode("utf-8")
    request = urllib.request.Request(
        TRILIUM_MCP_URL,
        data=payload,
        headers={"Accept": "application/json, text/event-stream", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            message = None
            for raw_line in response:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if line.startswith("data:"):
                    message = json.loads(line[5:].strip())
                    break
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Trilium MCP call {name} failed: {exc}") from exc
    if not message:
        raise RuntimeError(f"Trilium MCP call {name} returned no result.")
    if message.get("error"):
        raise RuntimeError(f"Trilium MCP call {name} failed: {message['error']}")
    result = message.get("result") or {}
    if result.get("isError"):
        raise RuntimeError(f"Trilium MCP call {name} failed: {result}")
    content = result.get("content") or []
    for item in content:
        if item.get("type") == "text":
            text = item.get("text", "")
            try:
                return json.loads(text)
            except json.JSONDecodeError:
                return text
    return result


def _trilium_children(note_id: str) -> list[dict]:
    value = _mcp_tool("get_child_notes", {"noteId": note_id})
    return value if isinstance(value, list) else []


def _trilium_child(note_id: str, title: str) -> dict | None:
    matches = [item for item in _trilium_children(note_id) if str(item.get("title")) == title]
    if len(matches) > 1:
        raise RuntimeError(f"Trilium contains more than one '{title}' child under note {note_id}.")
    return matches[0] if matches else None


def _trilium_note_content(note_id: str) -> str:
    value = _mcp_tool("get_note_content", {"noteId": note_id})
    if isinstance(value, dict):
        return str(value.get("content") or "")
    return str(value or "")


def _trilium_project_id(state: dict) -> str:
    project = str(state.get("project") or "").strip()
    if project == "AI IT Agents":
        return "EWSagIc6T5iH"
    escaped = project.replace("'", "\\'")
    value = _mcp_tool("search_notes", {"query": f"note.title = '{escaped}'", "fastSearch": True, "limit": 20})
    results = value.get("results", []) if isinstance(value, dict) else []
    matches = [item for item in results if str(item.get("title")) == project]
    if len(matches) != 1:
        raise RuntimeError(f"Trilium project note was not found unambiguously for {project}.")
    return str(matches[0]["noteId"])


def _ensure_trilium_child(parent_id: str, title: str, note_type: str, content: str = "") -> str:
    existing = _trilium_child(parent_id, title)
    if existing:
        return str(existing["noteId"])
    created = _mcp_tool("create_note", {"parentNoteId": parent_id, "title": title, "type": note_type, "content": content})
    if not isinstance(created, dict) or not created.get("noteId"):
        raise RuntimeError(f"Trilium did not return a note ID after creating {title}.")
    return str(created["noteId"])


def _set_trilium_label(note_id: str, name: str, value: str) -> None:
    _mcp_tool("set_attribute", {"noteId": note_id, "type": "label", "name": name, "value": value})


def _warning_status_rows(manifest: dict) -> list[dict]:
    rows = []
    for item in manifest.get("warnings", []):
        rows.append(
            {
                "id": str(item.get("id") or ""),
                "description": str(item.get("description") or ""),
                "status": str(item.get("status") or "open"),
                "verified": item.get("verified") is True,
                "tracked": True,
            }
        )
    for item in manifest.get("sourceResolvedWarnings", []):
        rows.append(
            {
                "id": str(item.get("id") or ""),
                "description": str(item.get("description") or ""),
                "status": "resolved before follow-up",
                "verified": True,
                "tracked": False,
            }
        )
    return sorted(rows, key=lambda item: int(re.sub(r"\D", "", item["id"]) or 0))


def _updated_validation_report_content(content: str, manifest: dict, live_id: str) -> str:
    tracked = manifest.get("warnings", [])
    resolved = [item for item in tracked if item.get("status") == "resolved" and item.get("verified") is True]
    remaining = [item for item in tracked if item.get("status") != "resolved" or item.get("verified") is not True]
    current = [
        "<!-- TT-WARNING-FOLLOWUP:START -->",
        "## Current Warning Follow-up",
        "",
        f"**Progress:** {len(resolved)} of {len(tracked)} tracked warnings resolved and verified.",
        "",
        f"**Next:** `/tt open {remaining[0].get('id')}`" if remaining else "**Next:** All tracked warnings are resolved and verified.",
        "",
        f"[Open the live warning tracker](#root/{live_id})",
        "",
        "The Stage 8 narrative below is retained as historical validation context. The Warnings Summary in this note is the current canonical status maintained by Hermes.",
        "<!-- TT-WARNING-FOLLOWUP:END -->",
    ]
    current_block = "\n".join(current)
    marker_pattern = r"(?ms)^<!-- TT-WARNING-FOLLOWUP:START -->\n.*?^<!-- TT-WARNING-FOLLOWUP:END -->"
    if re.search(marker_pattern, content):
        content = re.sub(marker_pattern, current_block, content, count=1)
    else:
        content = current_block + "\n\n---\n\n" + content

    table = [
        "## Warnings Summary — Current Status",
        "",
        "| ID | Description | Status | Verified |",
        "| --- | --- | --- | --- |",
    ]
    for item in _warning_status_rows(manifest):
        description = item["description"].replace("|", "\\|")
        verified = "Yes" if item["verified"] else "No"
        table.append(f"| {item['id']} | {description} | {item['status']} | {verified} |")
    table_block = "\n".join(table) + "\n\n"
    table_pattern = r"(?ms)^## Warnings Summary(?:[^\n]*)\n.*?(?=^---\s*$)"
    if not re.search(table_pattern, content):
        raise RuntimeError("Trilium Validation Report Warnings Summary section was not found unambiguously.")
    return re.sub(table_pattern, table_block, content, count=1)


def _sync_validation_report_status(round_id: str, manifest: dict, live_id: str) -> None:
    report = _trilium_child(round_id, "Validation Report")
    if not report:
        raise RuntimeError("Trilium Validation Report was not found for live warning synchronization.")
    report_id = str(report["noteId"])
    content = _trilium_note_content(report_id)
    if not content:
        raise RuntimeError("Trilium Validation Report content is empty.")
    content = _updated_validation_report_content(content, manifest, live_id)
    _mcp_tool("update_note_content", {"noteId": report_id, "content": content})
    tracked = manifest.get("warnings", [])
    resolved = [item for item in tracked if item.get("status") == "resolved" and item.get("verified") is True]
    remaining = [item for item in tracked if item.get("status") != "resolved" or item.get("verified") is not True]
    _set_trilium_label(report_id, "warningFollowupStatus", "resolved" if not remaining else "open")
    _set_trilium_label(report_id, "warningFollowupProgress", f"{len(resolved)}/{len(tracked)}")


def _warning_manifest(state: dict) -> dict | None:
    slug = str(state.get("slug") or "").strip()
    round_number = int(state.get("round") or 1)
    path = _hermes_home() / "pipelines" / slug / f"validation-warnings-round-{round_number}.json"
    return _read_state(path)


def _blocker_manifest(state: dict) -> dict | None:
    slug = str(state.get("slug") or "").strip()
    round_number = int(state.get("round") or 1)
    path = _hermes_home() / "pipelines" / slug / f"blockers-round-{round_number}.json"
    return _read_state(path)


def _blocker_value(value: object) -> str:
    if isinstance(value, list):
        return "\n".join(f"- {item}" for item in value) if value else "None recorded."
    if value is None or value == "":
        return "Not recorded."
    return str(value)


def _updated_adjudication_content(content: str, manifest: dict) -> str:
    blockers = [item for item in manifest.get("blockers", []) if isinstance(item, dict)]
    resolved = [item for item in blockers if item.get("status") == "resolved" and item.get("verified") is True]
    unresolved = [item for item in blockers if item.get("status") != "resolved" or item.get("verified") is not True]
    next_id = str(unresolved[0].get("id") or "") if unresolved else "None"
    status = f"{len(resolved)} of {len(blockers)} blockers resolved and verified"
    if unresolved:
        status += f" — next unresolved {next_id}"
    else:
        status = "all blockers resolved and verified"

    header_pattern = r"\*\*Status:\*\*.*?(?=\s+\*\*Blocker JSON:\*\*)"
    if not re.search(header_pattern, content):
        raise RuntimeError("Trilium Adjudication status field was not found unambiguously.")
    content = re.sub(header_pattern, f"**Status:** {status}", content, count=1)

    register = [
        "## Blocker Register",
        "",
        f"**Progress:** {len(resolved)} of {len(blockers)} blockers resolved and verified.",
        "",
        f"**Next unresolved blocker:** `/tt open {next_id}`" if unresolved else "**Next unresolved blocker:** None.",
        "",
        "| ID | Title | Type | Blocks | Owner | Status | Verified |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for item in blockers:
        values = [
            item.get("id"),
            item.get("title"),
            item.get("type"),
            item.get("blocksPhase"),
            item.get("owner"),
            item.get("status") or "open",
            "Yes" if item.get("verified") is True else "No",
        ]
        escaped = [str(value or "").replace("|", "\\|") for value in values]
        register.append("| " + " | ".join(escaped) + " |")
    register.extend(["", f"**{len(blockers)} blockers total. {len(resolved)} resolved and verified; {len(unresolved)} unresolved.**", ""])

    felton_unresolved = [item for item in unresolved if str(item.get("owner") or "").casefold() == "felton"]
    felton_resolved = [item for item in resolved if str(item.get("owner") or "").casefold() == "felton"]
    decisions = ["## Felton Decisions Required", ""]
    if not felton_unresolved:
        decisions.extend(["None. All Felton-owned blockers are resolved and verified.", ""])
    for item in felton_unresolved:
        decisions.extend(
            [
                f"### {item.get('id')} — {item.get('title')}",
                "",
                str(item.get("question") or "Not recorded."),
                "",
                f"**Recommendation:** {item.get('recommendation') or 'Not recorded.'}",
                "",
            ]
        )
    if felton_resolved:
        decisions.extend(["### Resolved Felton decisions", ""])
        for item in felton_resolved:
            decisions.extend(
                [
                    f"#### {item.get('id')} — {item.get('title')}",
                    "",
                    str(item.get("decision") or "Decision not recorded."),
                    "",
                    f"**Approved by:** {item.get('approvedBy') or 'Not recorded.'}  ",
                    f"**Approved at:** {item.get('approvedAt') or 'Not recorded.'}  ",
                    "**Verified:** Yes",
                    "",
                ]
            )
    managed_block = "\n".join(
        [
            *register,
            "---",
            "",
            *decisions,
            "",
        ]
    )
    blocker_region_pattern = r"(?ms)^## Blocker Register\s*\n.*?(?=^## Non-Blocker Findings Disposition\s*$)"
    if not re.search(blocker_region_pattern, content):
        raise RuntimeError("Trilium Adjudication blocker status region was not found unambiguously.")
    return re.sub(blocker_region_pattern, managed_block, content, count=1)


def _sync_adjudication_status(round_id: str, manifest: dict) -> None:
    adjudication = _trilium_child(round_id, "Adjudication")
    if not adjudication:
        raise RuntimeError("Trilium Adjudication note was not found for blocker synchronization.")
    note_id = str(adjudication["noteId"])
    content = _trilium_note_content(note_id)
    updated = _updated_adjudication_content(content, manifest)
    _mcp_tool("update_note_content", {"noteId": note_id, "content": updated})
    blockers = [item for item in manifest.get("blockers", []) if isinstance(item, dict)]
    unresolved = [item for item in blockers if item.get("status") != "resolved" or item.get("verified") is not True]
    _set_trilium_label(note_id, "blockerProgress", f"{len(blockers) - len(unresolved)}/{len(blockers)}")
    _set_trilium_label(note_id, "blockerStatus", "resolved" if not unresolved else "open")


def _sync_blocker_workshop(project_id: str, state: dict, manifest: dict) -> None:
    slug = str(state.get("slug") or "").strip()
    round_number = int(state.get("round") or 1)
    pipeline_id = _ensure_trilium_child(project_id, "Triple-Threat Pipeline", "book")
    round_id = _ensure_trilium_child(pipeline_id, f"Round {round_number}", "book")
    workshop_id = _ensure_trilium_child(
        round_id,
        "Blocker Workshop",
        "book",
        "Live adjudication blocker status synchronized from the Hermes runtime manifest.",
    )

    blockers = [item for item in manifest.get("blockers", []) if isinstance(item, dict)]
    resolved = [item for item in blockers if item.get("status") == "resolved" and item.get("verified") is True]
    unresolved = [item for item in blockers if item.get("status") != "resolved" or item.get("verified") is not True]

    tracker_lines = [
        "## Blocker Workshop — Live Tracker",
        "",
        "This is the current adjudication blocker status maintained by Hermes.",
        "",
        f"**Progress:** {len(resolved)} of {len(blockers)} blockers resolved and verified.",
        "",
        "| ID | Title | Owner | Status | Verified | Blocks |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for item in blockers:
        title = str(item.get("title") or "").replace("|", "\\|")
        owner = str(item.get("owner") or "").replace("|", "\\|")
        status = str(item.get("status") or "open").replace("|", "\\|")
        blocks = str(item.get("blocksPhase") or "").replace("|", "\\|")
        verified = "Yes" if item.get("verified") is True else "No"
        tracker_lines.append(f"| {item.get('id')} | {title} | {owner} | {status} | {verified} | {blocks} |")
    tracker_lines.extend(
        ["", f"**Next unresolved blocker:** `/tt open {unresolved[0].get('id')}`" if unresolved else "**Next unresolved blocker:** None. All blockers are resolved and verified."]
    )
    tracker_id = _ensure_trilium_child(workshop_id, "Blocker Workshop — Live Tracker", "text", "")
    _mcp_tool("update_note_content", {"noteId": tracker_id, "content": "\n".join(tracker_lines)})
    _set_trilium_label(tracker_id, "blockerWorkshopTracker", "true")
    _set_trilium_label(tracker_id, "projectSlug", slug)

    fields = [
        ("ID", "id"),
        ("Title", "title"),
        ("Owner", "owner"),
        ("Blocks phase", "blocksPhase"),
        ("Question", "question"),
        ("Why blocking", "whyBlocking"),
        ("Recommendation", "recommendation"),
        ("Alternatives", "alternatives"),
        ("Consequences", "consequences"),
        ("Status", "status"),
        ("Verified", "verified"),
        ("Decision", "decision"),
        ("Evidence", "evidence"),
        ("Approved by", "approvedBy"),
        ("Approved at", "approvedAt"),
    ]
    note_targets = []
    existing_notes = {str(item.get("title")): str(item.get("noteId")) for item in _trilium_children(workshop_id)}
    for item in blockers:
        blocker_id = str(item.get("id") or "").strip()
        blocker_title = str(item.get("title") or "Untitled blocker").strip()
        note_title = f"{blocker_id} — {blocker_title}"
        note_id = existing_notes.get(note_title)
        if not note_id:
            created = _mcp_tool("create_note", {"parentNoteId": workshop_id, "title": note_title, "type": "text", "content": ""})
            if not isinstance(created, dict) or not created.get("noteId"):
                raise RuntimeError(f"Trilium did not return a note ID after creating {note_title}.")
            note_id = str(created["noteId"])
        note_targets.append((note_id, blocker_id, blocker_title, item))

    def sync_blocker_note(target: tuple[str, str, str, dict]) -> None:
        note_id, blocker_id, blocker_title, item = target
        content_lines = [f"## {blocker_id} — {blocker_title}", ""]
        for label, key in fields:
            value = "Yes" if key == "verified" and item.get(key) is True else "No" if key == "verified" else _blocker_value(item.get(key))
            content_lines.extend([f"### {label}", "", value, ""])
        _mcp_tool("update_note_content", {"noteId": note_id, "content": "\n".join(content_lines).rstrip()})
        _set_trilium_label(note_id, "blockerId", blocker_id)
        _set_trilium_label(note_id, "projectSlug", slug)
        _set_trilium_label(note_id, "status", str(item.get("status") or "open"))
        _set_trilium_label(note_id, "verified", "true" if item.get("verified") is True else "false")
        _set_trilium_label(note_id, "blocksPhase", str(item.get("blocksPhase") or ""))

    if note_targets:
        with ThreadPoolExecutor(max_workers=min(4, len(note_targets)), thread_name_prefix="tt-trilium-blocker") as executor:
            list(executor.map(sync_blocker_note, note_targets))
    _sync_adjudication_status(round_id, manifest)


def _phase_tracker_mark(value: bool) -> str:
    return "x" if value else " "


def _phase_tracker_content(state: dict, warning_manifest: dict | None, blocker_manifest: dict | None) -> str:
    project = str(state.get("project") or state.get("slug") or "Project")
    status = str(state.get("status") or "unknown")
    gate = str(state.get("pendingGate") or "").strip()
    artifacts = state.get("artifacts") if isinstance(state.get("artifacts"), dict) else {}
    approvals = {str(item.get("gate")) for item in state.get("approvals", []) if isinstance(item, dict)}
    warnings = warning_manifest.get("warnings", []) if isinstance(warning_manifest, dict) else []
    unresolved_warnings = [item for item in warnings if item.get("status") != "resolved" or item.get("verified") is not True]
    blockers = blocker_manifest.get("blockers", []) if isinstance(blocker_manifest, dict) else []
    unresolved_blockers = [item for item in blockers if item.get("status") != "resolved" or item.get("verified") is not True]

    if status == "complete":
        current = "Workflow complete. All eight stages and every required gate are complete."
    elif status == "awaiting-approval":
        current = f"Paused at the {gate or 'unknown'} approval gate."
    elif status == "awaiting-workshop":
        current = "Paused in the adjudication blocker workshop."
    elif status == "failed":
        current = f"Failed at Stage {min(int(state.get('currentStage') or 1), 8)}."
    elif status == "running":
        current = f"Running Stage {min(int(state.get('currentStage') or 1), 8)}."
    else:
        current = f"Saved workflow status: {status}."

    if unresolved_blockers:
        next_action = f"/tt open {unresolved_blockers[0].get('id')}"
    elif unresolved_warnings:
        next_action = f"/tt open {unresolved_warnings[0].get('id')}"
    elif status == "awaiting-approval" and gate:
        next_action = f"/tt approve {gate}"
    elif status == "awaiting-workshop":
        next_action = "/tt work"
    elif status in {"ready", "running"}:
        next_action = "/tt continue"
    elif status == "failed" and int(state.get("currentStage") or 1) == 8:
        next_action = f"/tt Remediate validation for {project}"
    else:
        next_action = "None. The validated handoff is complete."

    stage_done = {number: f"stage{number}" in artifacts for number in range(1, 9)}
    lines = [
        f"## {project} — Triple-Threat Phase Tracker",
        "",
        f"**Current state:** {current}",
        "",
        f"**Next action:** `{next_action}`" if next_action.startswith("/") else f"**Next action:** {next_action}",
        "",
        f"**Pending gate:** {gate or 'None'}.",
        "",
        "**Coordinator:** Hermes using the deterministic repository orchestrator.",
        "",
        "**Safety:** Nothing has been deployed, installed, applied, activated, committed, or pushed.",
        "",
        "### Phases and gates",
        "",
        f"- [{_phase_tracker_mark(stage_done[1])}] Stage 1 — Project Design",
        f"- [{_phase_tracker_mark(stage_done[2])}] Stage 2 — Architecture",
        f"- [{_phase_tracker_mark('post-architecture' in approvals)}] Gate — Post-architecture approval",
        f"- [{_phase_tracker_mark(stage_done[3])}] Stage 3 — Codex Implementation Review",
        f"- [{_phase_tracker_mark(stage_done[4])}] Stage 4 — Antigravity Architecture Review",
        f"- [{_phase_tracker_mark(stage_done[5])}] Stage 5 — Adjudication",
        f"- [{_phase_tracker_mark('post-adjudication' in approvals)}] Workshop — Resolve and verify adjudication blockers",
        f"- [{_phase_tracker_mark('post-adjudication' in approvals)}] Gate — Finalize adjudication",
        f"- [{_phase_tracker_mark(stage_done[6])}] Stage 6 — Decision Register",
        f"- [{_phase_tracker_mark('post-decision-register' in approvals)}] Gate — Approve Decision Register",
        f"- [{_phase_tracker_mark(stage_done[7])}] Stage 7 — Build implementation package and runbook",
        f"- [{_phase_tracker_mark('post-implementation' in approvals)}] Gate — Approve implementation for validation",
        f"- [{_phase_tracker_mark(stage_done[8])}] Stage 8 — Read-only validation",
        f"- [{_phase_tracker_mark('post-validation' in approvals)}] Finalize validated runbook",
        f"- [{_phase_tracker_mark(status == 'complete')}] Ready for separate manual execution",
    ]
    if blockers:
        resolved_blocker_count = len(blockers) - len(unresolved_blockers)
        lines.extend(
            [
                "",
                "### Adjudication blocker workshop",
                "",
                f"**Progress:** {resolved_blocker_count} of {len(blockers)} blockers resolved and verified.",
                "",
                f"**Next unresolved blocker:** `/tt open {unresolved_blockers[0].get('id')}`"
                if unresolved_blockers
                else "**Next unresolved blocker:** None. All blockers are resolved and verified.",
            ]
        )
    if warnings:
        resolved_count = len(warnings) - len(unresolved_warnings)
        lines.extend(["", "### Validation warning follow-up", "", f"**Progress:** {resolved_count} of {len(warnings)} warnings resolved and verified.", ""])
        for item in warnings:
            checked = item.get("status") == "resolved" and item.get("verified") is True
            lines.append(f"- [{_phase_tracker_mark(checked)}] {item.get('id')} — {item.get('description')} [{item.get('status')}]" )
        lines.extend(["", "Commands: `/tt warnings`, `/tt open W3`, `/tt record W3 <resolution> --evidence <evidence>`, `/tt verify W3`."])
    return "\n".join(lines)


def _sync_trilium(state: dict) -> str:
    project = str(state.get("project") or "").strip()
    slug = str(state.get("slug") or "").strip()
    project_id = _trilium_project_id(state)
    tracker_title = f"{project} — Phase Tracker"
    tracker = _trilium_child(project_id, tracker_title)
    if not tracker:
        tracker_id = _ensure_trilium_child(project_id, tracker_title, "text", "")
    else:
        tracker_id = str(tracker["noteId"])

    blocker_manifest = _blocker_manifest(state)
    if blocker_manifest:
        _sync_blocker_workshop(project_id, state, blocker_manifest)

    warning_manifest = _warning_manifest(state)
    if warning_manifest:
        pipeline_id = _ensure_trilium_child(project_id, "Triple-Threat Pipeline", "book")
        round_id = _ensure_trilium_child(pipeline_id, f"Round {int(state.get('round') or 1)}", "book")
        warning_book_id = _ensure_trilium_child(round_id, "Validation Warnings", "book", "Post-validation follow-up items. Runtime JSON remains authoritative.")
        for item in warning_manifest.get("warnings", []):
            warning_id = str(item.get("id"))
            title = f"{warning_id} — Validation warning"
            content = "\n".join(
                [
                    f"## {warning_id} — Validation warning",
                    "",
                    f"**Status:** {item.get('status')}",
                    "",
                    "## Finding",
                    "",
                    str(item.get("description") or ""),
                    "",
                    "## Recorded resolution",
                    "",
                    str(item.get("decision") or "Not recorded."),
                    "",
                    "## Evidence",
                    "",
                    str(item.get("evidence") or "Not recorded."),
                    "",
                    f"**Verified:** {'Yes' if item.get('verified') is True else 'No'}",
                ]
            )
            note_id = _ensure_trilium_child(warning_book_id, title, "text", content)
            _mcp_tool("update_note_content", {"noteId": note_id, "content": content})
            _set_trilium_label(note_id, "validationWarningId", warning_id)
            _set_trilium_label(note_id, "status", str(item.get("status") or "open"))
            _set_trilium_label(note_id, "verified", "true" if item.get("verified") is True else "false")
            _set_trilium_label(note_id, "projectSlug", slug)

        for item in warning_manifest.get("sourceResolvedWarnings", []):
            warning_id = str(item.get("id"))
            title = f"{warning_id} — Validation warning"
            content = "\n".join(
                [
                    f"## {warning_id} — Validation warning",
                    "",
                    "**Status:** resolved before follow-up",
                    "",
                    "## Finding",
                    "",
                    str(item.get("description") or ""),
                    "",
                    "## Recorded resolution",
                    "",
                    "Resolved in the Stage 8 validation report; no follow-up action required.",
                    "",
                    "## Evidence",
                    "",
                    f"Stage 8 Validation Report status: {item.get('sourceStatus') or 'Resolved'}.",
                    "",
                    "**Verified:** Yes",
                ]
            )
            note_id = _ensure_trilium_child(warning_book_id, title, "text", content)
            _mcp_tool("update_note_content", {"noteId": note_id, "content": content})
            _set_trilium_label(note_id, "validationWarningId", warning_id)
            _set_trilium_label(note_id, "status", "resolved-before-followup")
            _set_trilium_label(note_id, "verified", "true")
            _set_trilium_label(note_id, "projectSlug", slug)

        warnings = warning_manifest.get("warnings", [])
        resolved = [item for item in warnings if item.get("status") == "resolved" and item.get("verified") is True]
        live_lines = [
            "## Validation Warnings — Live Tracker",
            "",
            "This is the current warning status maintained by Hermes. The canonical Validation Report's Warnings Summary is synchronized to this tracker; its original Stage 8 narrative is retained as historical context.",
            "",
            f"**Progress:** {len(resolved)} of {len(warnings)} warnings resolved and verified.",
            "",
            "| ID | Description | Status | Verified |",
            "| --- | --- | --- | --- |",
        ]
        for item in warnings:
            description = str(item.get("description") or "").replace("|", "\\|")
            verified = "Yes" if item.get("verified") is True else "No"
            live_lines.append(f"| {item.get('id')} | {description} | {item.get('status')} | {verified} |")
        remaining = [item for item in warnings if item.get("status") != "resolved" or item.get("verified") is not True]
        live_lines.extend(
            ["", f"**Next:** `/tt open {remaining[0].get('id')}`" if remaining else "**Next:** All validation warnings are resolved and verified."]
        )
        live_title = "Validation Warnings — Live Tracker"
        live_id = _ensure_trilium_child(warning_book_id, live_title, "text", "")
        _mcp_tool("update_note_content", {"noteId": live_id, "content": "\n".join(live_lines)})
        _set_trilium_label(live_id, "validationWarningTracker", "true")
        _set_trilium_label(live_id, "projectSlug", slug)
        _sync_validation_report_status(round_id, warning_manifest, live_id)

    tracker_content = _phase_tracker_content(state, warning_manifest, blocker_manifest)
    _mcp_tool("update_note_content", {"noteId": tracker_id, "content": tracker_content})
    _set_trilium_label(tracker_id, "tripleThreatTracker", "true")
    _set_trilium_label(tracker_id, "projectSlug", slug)
    _set_trilium_label(tracker_id, "pipelineStatus", str(state.get("status") or "unknown"))
    current_stage = "complete" if state.get("status") == "complete" else str(min(int(state.get("currentStage") or 1), 8))
    _set_trilium_label(tracker_id, "currentStage", current_stage)
    _set_trilium_label(tracker_id, "pendingGate", str(state.get("pendingGate") or ""))
    return f"Trilium synchronized: {tracker_title}"


def _sync_saved_project(state: dict) -> str:
    slug = str(state.get("slug") or "").strip()
    saved_path = _hermes_home() / "pipelines" / slug / "state.json"
    saved = _read_state(saved_path)
    if not saved:
        raise RuntimeError(f"Saved Triple-Threat state could not be read after the command: {saved_path}")
    saved["_state_path"] = str(saved_path)
    return _sync_trilium(saved)


def _active_project() -> dict:
    pipeline_root = _hermes_home() / "pipelines"
    candidates = []
    all_states = []
    if pipeline_root.is_dir():
        for state_path in pipeline_root.glob("*/state.json"):
            state = _read_state(state_path)
            if not state:
                continue
            state["_state_path"] = str(state_path)
            all_states.append(state)
            if state.get("status") in ACTIVE_STATUSES or state.get("pendingGate"):
                candidates.append(state)

    workshop = [
        state
        for state in candidates
        if state.get("status") == "awaiting-workshop"
        or state.get("pendingGate") == "post-adjudication"
    ]
    selected = workshop or candidates or all_states
    if not selected:
        raise RuntimeError("No active Triple-Threat project was found.")
    if len(selected) > 1:
        names = ", ".join(str(item.get("project") or item.get("slug")) for item in selected)
        raise RuntimeError(f"More than one Triple-Threat project is active: {names}")
    return selected[0]


def _split_args(raw_args: str) -> list[str]:
    try:
        return shlex.split(raw_args, posix=True)
    except ValueError as exc:
        raise RuntimeError(f"Invalid command quoting: {exc}") from exc


def _read_hermes_paste(path_text: str) -> str:
    paste_root = (_hermes_home() / "pastes").resolve()
    cleaned = path_text.strip()
    if len(cleaned) >= 2 and cleaned[0] == cleaned[-1] and cleaned[0] in {'"', "'"}:
        cleaned = cleaned[1:-1]
    if not cleaned:
        raise RuntimeError("paste requires the saved Hermes paste-file path.")

    paste_path = Path(cleaned).expanduser().resolve()
    try:
        paste_path.relative_to(paste_root)
    except ValueError as exc:
        raise RuntimeError(f"Paste files must be inside Hermes local paste storage: {paste_root}") from exc
    if not paste_path.is_file():
        raise RuntimeError(f"Hermes paste file was not found: {paste_path}")
    if paste_path.stat().st_size > MAX_PASTE_BYTES:
        raise RuntimeError(f"Hermes paste file exceeds the {MAX_PASTE_BYTES // 1024} KiB safety limit.")

    content = paste_path.read_text(encoding="utf-8-sig").strip()
    if not content:
        raise RuntimeError(f"Hermes paste file is empty: {paste_path}")
    if content.lower().startswith("/tt "):
        content = content[4:].lstrip()
    elif content.lower().startswith("tt "):
        content = content[3:].lstrip()
    return content


def _expand_paste_action(raw_args: str) -> str:
    match = re.fullmatch(r"\s*paste(?:\s+(.+?))?\s*", raw_args, re.IGNORECASE | re.DOTALL)
    if not match:
        return raw_args
    return _read_hermes_paste(match.group(1) or "")


def _parse(raw_args: str) -> tuple[str, str | None, str | None, str | None, str | None]:
    parts = _split_args(raw_args)
    if not parts or parts[0].lower() in {"help", "?"}:
        return "help", None, None, None, None
    action = parts.pop(0).lower()
    if action not in WORKSHOP_ACTIONS:
        raise RuntimeError(f"Unknown Triple-Threat workshop action: {action}\n\n{HELP}")

    blocker_id = None
    decision = None
    evidence = None
    blocker_title = None
    if action in ID_ACTIONS:
        if parts and parts[0].lower() in {"block", "blocker"}:
            parts.pop(0)
        if not parts or not re.fullmatch(r"B\d+", parts[0], re.IGNORECASE):
            raise RuntimeError(f"{action} requires a blocker ID such as B1.")
        blocker_id = parts.pop(0).upper()

    if action == "create":
        blocker_title = " ".join(parts).strip()
        if not blocker_title:
            raise RuntimeError("create requires a blocker title.")
    elif action == "record":
        if "--evidence" in parts:
            marker = parts.index("--evidence")
            decision_parts, evidence_parts = parts[:marker], parts[marker + 1 :]
            evidence = " ".join(evidence_parts).strip()
            if not evidence:
                raise RuntimeError("--evidence must be followed by evidence text.")
        else:
            decision_parts = parts
        decision = " ".join(decision_parts).strip()
        if not decision:
            raise RuntimeError("record requires decision text after the blocker ID.")
    elif parts:
        raise RuntimeError(f"Unexpected text after {action}: {' '.join(parts)}")

    return action, blocker_id, decision, evidence, blocker_title


def _run_workshop(
    action: str,
    blocker_id: str | None,
    decision: str | None,
    evidence: str | None,
    blocker_title: str | None,
) -> str:
    state = _active_project()
    project = str(state.get("project") or "").strip()
    slug = str(state.get("slug") or "").strip()
    project_dir = str(state.get("projectDir") or project).strip()
    trilium_path = str(state.get("triliumProjectPath") or f"Planner/Projects/{project}").strip()
    if not project or not slug or not project_dir:
        raise RuntimeError(f"Active state is missing project metadata: {state.get('_state_path')}")

    runner = _repo_root() / "hermes" / "skills" / "triple-threat-orchestrator" / "run.ps1"
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(runner),
        "-Project",
        project,
        "-ProjectSlug",
        slug,
        "-ProjectDir",
        project_dir,
        "-TriliumProjectPath",
        trilium_path,
        "-WorkshopAction",
        action,
    ]
    if blocker_id:
        command.extend(["-BlockerId", blocker_id])
    if decision:
        command.extend(["-Decision", decision])
    if evidence:
        command.extend(["-Evidence", evidence])
    if blocker_title:
        command.extend(["-BlockerTitle", blocker_title])
    if action in MUTATING_ACTIONS:
        command.extend(["-TransactionId", str(uuid.uuid4())])

    completed = subprocess.run(
        command,
        cwd=str(_repo_root()),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=30,
        stdin=subprocess.DEVNULL,
        shell=False,
    )
    output = "\n".join(part.strip() for part in (completed.stdout, completed.stderr) if part.strip())
    if completed.returncode:
        raise RuntimeError(output or f"Triple-Threat command failed with exit code {completed.returncode}.")
    sync = _sync_saved_project(state)
    return "\n".join(part for part in (output or "Triple-Threat command completed.", sync) if part)


def _run_validation_warning(raw_args: str) -> str | None:
    parts = _split_args(raw_args)
    if not parts:
        return None
    action = parts[0].lower()
    warning_id = None
    decision = None
    evidence = None
    if action == "warnings":
        if len(parts) != 1:
            raise RuntimeError("warnings does not accept additional text.")
        warning_action = "show"
    elif action == "reconcile" and len(parts) == 2 and parts[1].lower() == "warnings":
        warning_action = "reconcile"
    elif action in {"open", "record", "verify"} and len(parts) >= 2 and re.fullmatch(r"W\d+", parts[1], re.IGNORECASE):
        warning_action = action
        warning_id = parts[1].upper()
        remaining = parts[2:]
        if action == "record":
            if "--evidence" in remaining:
                marker = remaining.index("--evidence")
                decision = " ".join(remaining[:marker]).strip()
                evidence = " ".join(remaining[marker + 1 :]).strip()
                if not evidence:
                    raise RuntimeError("--evidence must be followed by evidence text.")
            else:
                decision = " ".join(remaining).strip()
            if not decision:
                raise RuntimeError("record requires resolution text after the warning ID.")
        elif remaining:
            raise RuntimeError(f"Unexpected text after {action} {warning_id}: {' '.join(remaining)}")
    else:
        return None

    state = _active_project()
    command = _workflow_command(state) + ["-ValidationWarningAction", warning_action]
    if warning_id:
        command.extend(["-WarningId", warning_id])
    if decision:
        command.extend(["-WarningDecision", decision])
    if evidence:
        command.extend(["-WarningEvidence", evidence])
    if warning_action in {"reconcile", "record", "verify"}:
        command.extend(["-TransactionId", str(uuid.uuid4())])
    completed = subprocess.run(
        command,
        cwd=str(_repo_root()),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=30,
        stdin=subprocess.DEVNULL,
        shell=False,
    )
    output = "\n".join(part.strip() for part in (completed.stdout, completed.stderr) if part.strip())
    if completed.returncode:
        raise RuntimeError(output or f"Triple-Threat warning command failed with exit code {completed.returncode}.")
    sync = _sync_saved_project(state)
    return "\n".join(part for part in (output or "Validation warning command completed.", sync) if part)


def _state_for_project(project_name: str | None = None) -> dict:
    if not project_name:
        return _active_project()
    wanted = project_name.strip()
    pipeline_root = _hermes_home() / "pipelines"
    if pipeline_root.is_dir():
        for state_path in pipeline_root.glob("*/state.json"):
            state = _read_state(state_path)
            if state and str(state.get("project") or "").casefold() == wanted.casefold():
                state["_state_path"] = str(state_path)
                return state

    repo = _repo_root()
    matches = [item for item in repo.iterdir() if item.is_dir() and item.name.casefold() == wanted.casefold()]
    if len(matches) != 1:
        raise RuntimeError(f"Project directory was not found unambiguously: {wanted}")
    title = matches[0].name
    slug = re.sub(r"[^a-z0-9]+", "-", title.casefold()).strip("-")
    return {
        "project": title,
        "slug": slug,
        "projectDir": title,
        "triliumProjectPath": f"Planner/Projects/{title}",
    }


def _workflow_command(state: dict) -> list[str]:
    project = str(state.get("project") or "").strip()
    slug = str(state.get("slug") or "").strip()
    project_dir = str(state.get("projectDir") or project).strip()
    trilium_path = str(state.get("triliumProjectPath") or f"Planner/Projects/{project}").strip()
    if not project or not slug or not project_dir:
        raise RuntimeError("Triple-Threat state is missing project metadata.")
    runner = _repo_root() / "hermes" / "skills" / "triple-threat-orchestrator" / "run.ps1"
    return [
        "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(runner),
        "-Project", project, "-ProjectSlug", slug, "-ProjectDir", project_dir,
        "-TriliumProjectPath", trilium_path,
    ]


def _command_lock_path() -> Path:
    return _hermes_home() / "triple-threat-command.json"


def _pid_is_running(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes

        process_query_limited_information = 0x1000
        still_active = 259
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        handle = kernel32.OpenProcess(process_query_limited_information, False, pid)
        if not handle:
            return False
        try:
            exit_code = ctypes.c_ulong()
            if not kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
                return False
            return exit_code.value == still_active
        finally:
            kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _active_background_command() -> dict | None:
    lock_path = _command_lock_path()
    lock = _read_state(lock_path)
    if not lock:
        return None
    try:
        pid = int(lock.get("pid") or 0)
    except (TypeError, ValueError):
        pid = 0
    if _pid_is_running(pid):
        return lock
    try:
        lock_path.unlink(missing_ok=True)
    except OSError:
        pass
    return None


def _pipeline_status(state: dict) -> str:
    project = str(state.get("project") or state.get("slug") or "Triple-Threat project")
    status = str(state.get("status") or "unknown")
    stage = int(state.get("currentStage") or 1)
    gate = str(state.get("pendingGate") or "").strip()
    completed = 8 if status == "complete" else max(0, min(8, stage - 1))
    lines = [f"{project}: {completed} of 8 stages complete."]

    if status == "running":
        lines.append(f"Running Stage {min(stage, 8)}.")
    elif status == "awaiting-workshop":
        lines.append("Paused in the adjudication blocker workshop.")
        lines.append("Next: /tt work")
    elif status == "awaiting-approval":
        lines.append(f"Pending gate: {gate or 'unknown'}.")
        if gate:
            lines.append(f"Next: /tt approve {gate}")
    elif status == "failed":
        lines.append(f"Failed at Stage {min(stage, 8)}.")
        error = str(state.get("lastError") or "").strip()
        if error:
            lines.append(f"Error: {error}")
        if stage == 8:
            lines.append(f"Next: /tt Remediate validation for {project}")
    elif status == "ready":
        lines.append(f"Ready to start Stage {min(stage, 8)}.")
        lines.append("Next: /tt continue")
    elif status == "complete":
        lines.append("Workflow complete. Nothing was deployed or activated.")
    else:
        lines.append(f"Saved status: {status}.")
    return "\n".join(lines)


def _read_command_result(stdout_path: Path, stderr_path: Path, return_code: int) -> str:
    parts = []
    for path in (stdout_path, stderr_path):
        try:
            value = path.read_text(encoding="utf-8-sig").strip()
        except (OSError, UnicodeError):
            value = ""
        if value:
            parts.append(value)
    output = "\n".join(parts)
    if return_code:
        return output or f"Triple-Threat command failed with exit code {return_code}."
    return output or "Triple-Threat command completed successfully."


def _watch_background_command(
    process: subprocess.Popen,
    transaction_id: str,
    description: str,
    stdout_path: Path,
    stderr_path: Path,
    state: dict,
) -> None:
    return_code = process.wait()
    result = _read_command_result(stdout_path, stderr_path, return_code)
    lock_path = _command_lock_path()
    lock = _read_state(lock_path)
    if lock and lock.get("transactionId") == transaction_id:
        try:
            lock_path.unlink(missing_ok=True)
        except OSError:
            pass
    if return_code == 0:
        try:
            result = "\n".join((result, _sync_saved_project(state)))
        except Exception as exc:
            result = "\n".join((result, f"Trilium synchronization failed: {exc}"))
            return_code = 1
    outcome = "completed" if return_code == 0 else "failed"
    print(f"\nTriple-Threat {outcome}: {description}\n{result}\n", flush=True)


def _launch_workflow(command: list[str], state: dict, description: str) -> str:
    active = _active_background_command()
    if active:
        return (
            f"Triple-Threat is already running: {active.get('description', 'workflow command')}\n"
            f"Transaction: {active.get('transactionId', 'unknown')}\n"
            "Use /tt status for saved workflow progress. Do not submit the command again."
        )

    transaction_id = command[command.index("-TransactionId") + 1]
    slug = str(state.get("slug") or "triple-threat").strip()
    pipeline_dir = _hermes_home() / "pipelines" / slug
    pipeline_dir.mkdir(parents=True, exist_ok=True)
    stdout_path = pipeline_dir / f"tt-command-{transaction_id}.stdout.log"
    stderr_path = pipeline_dir / f"tt-command-{transaction_id}.stderr.log"
    creation_flags = 0
    if os.name == "nt":
        creation_flags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
    with stdout_path.open("w", encoding="utf-8") as stdout_file, stderr_path.open("w", encoding="utf-8") as stderr_file:
        process = subprocess.Popen(
            command,
            cwd=str(_repo_root()),
            stdout=stdout_file,
            stderr=stderr_file,
            stdin=subprocess.DEVNULL,
            shell=False,
            creationflags=creation_flags,
        )
    lock = {
        "pid": process.pid,
        "transactionId": transaction_id,
        "description": description,
        "project": state.get("project"),
        "slug": slug,
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "stdout": str(stdout_path),
        "stderr": str(stderr_path),
    }
    _command_lock_path().write_text(json.dumps(lock, indent=2), encoding="utf-8")
    threading.Thread(
        target=_watch_background_command,
        args=(process, transaction_id, description, stdout_path, stderr_path, state),
        daemon=True,
        name=f"triple-threat-{transaction_id}",
    ).start()
    return (
        f"Started: {description}\n"
        f"Transaction: {transaction_id}\n"
        "Hermes will print the final result here when it finishes. "
        "Use /tt status for an interim check; do not submit the command again."
    )


def _run_full_workflow(raw_args: str) -> str | None:
    text = raw_args.strip()
    if re.fullmatch(r"test\s+feedback", text, re.IGNORECASE):
        state = _active_project()
        transaction_id = str(uuid.uuid4())
        command = [
            sys.executable,
            "-c",
            "import time; time.sleep(1); print('Feedback test passed. Hermes reported this completion automatically.')",
            "-TransactionId",
            transaction_id,
        ]
        return _launch_workflow(command, state, "Test Triple-Threat completion feedback")
    status_match = re.fullmatch(r"status(?:\s+(.+))?", text, re.IGNORECASE)
    if status_match:
        active = _active_background_command()
        state = _state_for_project(status_match.group(1))
        status = _pipeline_status(state)
        if active:
            return (
                f"Running: {active.get('description', 'Triple-Threat workflow')}\n"
                f"Transaction: {active.get('transactionId', 'unknown')}\n\n{status}"
            )
        return status
    if re.fullmatch(r"(?:work\s+)?adjudication\s+blockers", text, re.IGNORECASE):
        return _run_workshop("work", None, None, None, None)
    if re.fullmatch(r"finalize\s+adjudication", text, re.IGNORECASE):
        state = _active_project()
        command = _workflow_command(state) + ["-WorkshopAction", "finalize", "-TransactionId", str(uuid.uuid4())]
        return _launch_workflow(command, state, f"Finalize adjudication for {state.get('project')}")

    match = re.fullmatch(r"remediate\s+validation(?:\s+for\s+(.+))?", text, re.IGNORECASE)
    if match:
        state = _state_for_project(match.group(1))
        command = _workflow_command(state) + ["-RemediateValidation", "-TransactionId", str(uuid.uuid4())]
        return _launch_workflow(command, state, f"Remediate validation for {state.get('project')}")

    match = re.fullmatch(r"approve\s+(post-(?:architecture|adjudication|decision-register|implementation|validation))", text, re.IGNORECASE)
    if match:
        state = _state_for_project()
        command = _workflow_command(state) + ["-ApproveGate", match.group(1).lower(), "-TransactionId", str(uuid.uuid4())]
        return _launch_workflow(command, state, f"Approve {match.group(1).lower()} for {state.get('project')}")

    if re.fullmatch(r"finalize\s+validated\s+runbook", text, re.IGNORECASE):
        state = _active_project()
        command = _workflow_command(state) + ["-ApproveGate", "post-validation", "-TransactionId", str(uuid.uuid4())]
        return _launch_workflow(command, state, f"Finalize validated runbook for {state.get('project')}")

    match = re.fullmatch(r"resume\s+stage\s+([1-8])", text, re.IGNORECASE)
    if match:
        stage = match.group(1)
        state = _state_for_project()
        command = _workflow_command(state) + ["-FromStage", stage, "-ToStage", "8", "-TransactionId", str(uuid.uuid4())]
        return _launch_workflow(command, state, f"Resume Stage {stage} for {state.get('project')}")

    if re.fullmatch(r"continue", text, re.IGNORECASE):
        state = _state_for_project()
        command = _workflow_command(state) + ["-TransactionId", str(uuid.uuid4())]
        return _launch_workflow(command, state, f"Continue {state.get('project')}")

    match = re.fullmatch(r"triple\s+threat:\s*(.+)", text, re.IGNORECASE)
    if match:
        state = _state_for_project(match.group(1))
        command = _workflow_command(state) + ["-TransactionId", str(uuid.uuid4())]
        return _launch_workflow(command, state, f"Start or resume {state.get('project')}")

    return None


def _handle(raw_args: str) -> str:
    try:
        raw_args = _expand_paste_action(raw_args)
        warning_result = _run_validation_warning(raw_args)
        if warning_result is not None:
            return warning_result
        full_result = _run_full_workflow(raw_args)
        if full_result is not None:
            return full_result
        action, blocker_id, decision, evidence, blocker_title = _parse(raw_args)
        if action == "help":
            return HELP
        return _run_workshop(action, blocker_id, decision, evidence, blocker_title)
    except subprocess.TimeoutExpired:
        return "Triple-Threat command exceeded its six-hour safety limit and was stopped."
    except Exception as exc:
        return f"Triple-Threat workshop error: {exc}"


def _dispatch(raw_args: str) -> str | None:
    """Deliver slash-command output on every interactive Hermes surface.

    Hermes v0.18.2's refreshed TUI can discard a plugin handler's returned
    string after it has already restored the prompt.  Interactive CLI and
    slash-worker sessions both capture stdout, so print the completed result
    there and return None to prevent duplicate rendering.  Non-interactive
    gateway callers still receive the normal return value.
    """
    result = _handle(raw_args)
    interactive = os.environ.get("HERMES_INTERACTIVE", "").strip().lower() in {"1", "true", "yes", "on"}
    gateway = os.environ.get("HERMES_GATEWAY_SESSION", "").strip().lower() in {"1", "true", "yes", "on"}
    if interactive and not gateway:
        print(result)
        return None
    return result


def register(ctx) -> None:
    ctx.register_command(
        "tt",
        _dispatch,
        description="Run the complete deterministic Triple-Threat workflow",
        args_hint="status | continue | approve <gate> | work | open B1 | record B1 <decision> | verify B1",
    )
