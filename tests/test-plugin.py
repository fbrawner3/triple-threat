import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[3]
PLUGIN_PATH = REPO / "hermes" / "plugins" / "triple-threat" / "__init__.py"
SPEC = importlib.util.spec_from_file_location("triple_threat_plugin", PLUGIN_PATH)
PLUGIN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLUGIN)


class TripleThreatPluginTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=REPO)
        self.original_home = os.environ.get("HERMES_HOME")
        os.environ["HERMES_HOME"] = self.temp.name

    def tearDown(self):
        if self.original_home is None:
            os.environ.pop("HERMES_HOME", None)
        else:
            os.environ["HERMES_HOME"] = self.original_home
        self.temp.cleanup()

    def test_status_reports_pipeline_phase_not_only_blockers(self):
        state = {
            "project": "AI IT Agents",
            "currentStage": 9,
            "status": "awaiting-approval",
            "pendingGate": "post-validation",
        }
        result = PLUGIN._pipeline_status(state)
        self.assertIn("8 of 8 stages complete", result)
        self.assertIn("Pending gate: post-validation", result)
        self.assertIn("/tt approve post-validation", result)

    def test_pid_check_rejects_dead_process(self):
        self.assertTrue(PLUGIN._pid_is_running(os.getpid()))
        self.assertFalse(PLUGIN._pid_is_running(999999))

    def test_background_command_prints_completion_and_removes_lock(self):
        transaction_id = "11111111-1111-1111-1111-111111111111"
        command = [
            sys.executable,
            "-c",
            "print('stage result returned')",
            "-TransactionId",
            transaction_id,
        ]
        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch.object(PLUGIN, "_sync_saved_project", return_value="Trilium synchronized"):
            started = PLUGIN._launch_workflow(command, {"slug": "test", "project": "Test"}, "Test run")
            deadline = time.time() + 10
            while "Triple-Threat completed: Test run" not in output.getvalue() and time.time() < deadline:
                time.sleep(0.05)
        self.assertIn("will print the final result", started)
        self.assertIn("Triple-Threat completed: Test run", output.getvalue())
        self.assertIn("stage result returned", output.getvalue())
        self.assertFalse(PLUGIN._command_lock_path().exists())

    def test_finalize_commands_use_background_workflow_with_transaction(self):
        state = {"project": "Test", "slug": "test", "projectDir": "Test", "triliumProjectPath": "Planner/Projects/Test"}
        with patch.object(PLUGIN, "_active_project", return_value=state), patch.object(
            PLUGIN, "_launch_workflow", return_value="started"
        ) as launch:
            self.assertEqual(PLUGIN._run_full_workflow("finalize adjudication"), "started")
            command = launch.call_args.args[0]
            self.assertIn("-WorkshopAction", command)
            self.assertIn("finalize", command)
            self.assertIn("-TransactionId", command)

            self.assertEqual(PLUGIN._run_full_workflow("finalize validated runbook"), "started")
            command = launch.call_args.args[0]
            self.assertIn("post-validation", command)
            self.assertIn("-TransactionId", command)

    def test_every_full_workflow_route_launches_once_with_transaction(self):
        state = {"project": "Test", "slug": "test", "projectDir": "Test", "triliumProjectPath": "Planner/Projects/Test"}
        commands = [
            "Remediate validation for Test",
            "approve post-architecture",
            "approve post-decision-register",
            "approve post-implementation",
            "approve post-validation",
            "resume Stage 7",
            "continue",
            "Triple threat: Test",
        ]
        with patch.object(PLUGIN, "_active_project", return_value=state), patch.object(
            PLUGIN, "_state_for_project", return_value=state
        ), patch.object(PLUGIN, "_launch_workflow", return_value="started") as launch:
            for text in commands:
                launch.reset_mock()
                self.assertEqual(PLUGIN._run_full_workflow(text), "started")
                launch.assert_called_once()
                command = launch.call_args.args[0]
                self.assertEqual(command.count("-TransactionId"), 1)

    def test_feedback_acceptance_route_is_non_workflow_process(self):
        state = {"project": "Test", "slug": "test", "projectDir": "Test", "triliumProjectPath": "Planner/Projects/Test"}
        with patch.object(PLUGIN, "_active_project", return_value=state), patch.object(
            PLUGIN, "_launch_workflow", return_value="started"
        ) as launch:
            self.assertEqual(PLUGIN._run_full_workflow("test feedback"), "started")
            command = launch.call_args.args[0]
            self.assertEqual(command[0], sys.executable)
            self.assertNotIn("run.ps1", " ".join(command))
            self.assertEqual(command.count("-TransactionId"), 1)

    def test_workshop_parser_preserves_decision_and_evidence(self):
        action, blocker, decision, evidence, title = PLUGIN._parse(
            'record B8 "Keep CPU threshold at 95 percent" --evidence "validated in Hexmap"'
        )
        self.assertEqual((action, blocker, title), ("record", "B8", None))
        self.assertEqual(decision, "Keep CPU threshold at 95 percent")
        self.assertEqual(evidence, "validated in Hexmap")

    def test_workshop_parser_accepts_generated_blocker_wording(self):
        for text in ("verify B8", "verify block B8", "verify blocker B8"):
            action, blocker, decision, evidence, title = PLUGIN._parse(text)
            self.assertEqual((action, blocker, decision, evidence, title), ("verify", "B8", None, None, None))

    def test_validation_warning_commands_route_without_agents(self):
        state = {"project": "Test", "slug": "test", "projectDir": "Test", "triliumProjectPath": "Planner/Projects/Test"}
        completed = type("Completed", (), {"returncode": 0, "stdout": "warning result", "stderr": ""})()
        cases = [
            ("warnings", "show", None, None, None, False),
            ("reconcile warnings", "reconcile", None, None, None, True),
            ("open W3", "open", "W3", None, None, False),
            ('record W3 "Fix error workflow" --evidence "verified export"', "record", "W3", "Fix error workflow", "verified export", True),
            ("verify W3", "verify", "W3", None, None, True),
        ]
        with patch.object(PLUGIN, "_active_project", return_value=state), patch.object(
            PLUGIN.subprocess, "run", return_value=completed
        ) as run, patch.object(PLUGIN, "_sync_saved_project", return_value="Trilium synchronized"):
            for text, action, warning_id, decision, evidence, mutating in cases:
                run.reset_mock()
                result = PLUGIN._run_validation_warning(text)
                self.assertIn("Trilium synchronized", result)
                command = run.call_args.args[0]
                self.assertEqual(command[command.index("-ValidationWarningAction") + 1], action)
                if warning_id:
                    self.assertEqual(command[command.index("-WarningId") + 1], warning_id)
                if decision:
                    self.assertEqual(command[command.index("-WarningDecision") + 1], decision)
                if evidence:
                    self.assertEqual(command[command.index("-WarningEvidence") + 1], evidence)
                self.assertEqual("-TransactionId" in command, mutating)

    def test_interactive_dispatch_prints_result_instead_of_returning_it(self):
        output = io.StringIO()
        with patch.dict(os.environ, {"HERMES_INTERACTIVE": "1"}), patch.object(
            PLUGIN, "_handle", return_value="W3 details"
        ), contextlib.redirect_stdout(output):
            result = PLUGIN._dispatch("open W3")
        self.assertIsNone(result)
        self.assertEqual(output.getvalue().strip(), "W3 details")

    def test_noninteractive_dispatch_returns_result(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(
            PLUGIN, "_handle", return_value="W3 details"
        ):
            result = PLUGIN._dispatch("open W3")
        self.assertEqual(result, "W3 details")

    def test_tui_gateway_dispatch_returns_result(self):
        output = io.StringIO()
        with patch.dict(
            os.environ,
            {"HERMES_INTERACTIVE": "1", "HERMES_GATEWAY_SESSION": "1"},
            clear=True,
        ), patch.object(PLUGIN, "_handle", return_value="W3 details"), contextlib.redirect_stdout(output):
            result = PLUGIN._dispatch("open W3")
        self.assertEqual(result, "W3 details")
        self.assertEqual(output.getvalue(), "")

    def test_phase_tracker_shows_warning_followup_without_stage_nine(self):
        state = {
            "project": "AI IT Agents",
            "slug": "ai-it-agents",
            "currentStage": 9,
            "status": "complete",
            "pendingGate": None,
            "artifacts": {f"stage{number}": ["artifact"] for number in range(1, 9)},
            "approvals": [
                {"gate": gate}
                for gate in (
                    "post-architecture",
                    "post-adjudication",
                    "post-decision-register",
                    "post-implementation",
                    "post-validation",
                )
            ],
        }
        warnings = {
            "warnings": [
                {"id": "W3", "description": "Configure the error workflow", "status": "open", "verified": False}
            ]
        }
        content = PLUGIN._phase_tracker_content(state, warnings, None)
        self.assertIn("0 of 1 warnings resolved and verified", content)
        self.assertIn("/tt open W3", content)
        self.assertIn("- [x] Stage 8", content)
        self.assertNotIn("Stage 9", content)

    def test_blocker_manifest_uses_saved_slug_and_round(self):
        pipeline = Path(self.temp.name) / "pipelines" / "test-project"
        pipeline.mkdir(parents=True)
        expected = {"blockers": [{"id": "B1"}]}
        (pipeline / "blockers-round-2.json").write_text(json.dumps(expected), encoding="utf-8")
        self.assertEqual(PLUGIN._blocker_manifest({"slug": "test-project", "round": 2}), expected)

    def test_phase_tracker_prioritizes_unresolved_adjudication_blocker(self):
        state = {
            "project": "Test",
            "slug": "test",
            "currentStage": 6,
            "status": "awaiting-workshop",
            "pendingGate": "post-adjudication",
            "artifacts": {f"stage{number}": ["artifact"] for number in range(1, 6)},
            "approvals": [{"gate": "post-architecture"}],
        }
        blockers = {
            "blockers": [
                {"id": "B1", "title": "Done", "status": "resolved", "verified": True},
                {"id": "B2", "title": "Next", "status": "open", "verified": False},
            ]
        }
        content = PLUGIN._phase_tracker_content(state, None, blockers)
        self.assertIn("1 of 2 blockers resolved and verified", content)
        self.assertIn("**Next action:** `/tt open B2`", content)
        self.assertIn("**Next unresolved blocker:** `/tt open B2`", content)

    def test_adjudication_note_uses_current_blocker_manifest(self):
        original = """## Test — Round 1 Adjudication

**Stage:** 4 **Status:** open — awaiting Felton decisions on B1 and B2 **Blocker JSON:** `blockers.json`

---

## Adjudication Summary

Narrative must be preserved.

---

## Blocker Register

| ID | Title | Type | Blocks | Owner | Status |
| --- | --- | --- | --- | --- | --- |
| B1 | Old title | decision-gap | Phase 1 | Felton | open |
| B2 | Other | evidence-gap | Phase 2 | executor | open |

**2 blockers total.**

---

## Felton Decisions Required

Stale decision text.

---

## Non-Blocker Findings Disposition

Preserve this too.
"""
        manifest = {
            "blockers": [
                {
                    "id": "B1",
                    "title": "Current title",
                    "type": "decision-gap",
                    "blocksPhase": "Phase 1",
                    "owner": "Felton",
                    "status": "resolved",
                    "verified": True,
                    "decision": "Approved current decision.",
                    "approvedBy": "Felton",
                    "approvedAt": "2026-07-22T10:00:00-05:00",
                },
                {
                    "id": "B2",
                    "title": "Other",
                    "type": "evidence-gap",
                    "blocksPhase": "Phase 2",
                    "owner": "executor",
                    "status": "open",
                    "verified": False,
                },
            ]
        }
        updated = PLUGIN._updated_adjudication_content(original, manifest)
        self.assertIn("**Status:** 1 of 2 blockers resolved and verified — next unresolved B2", updated)
        self.assertIn("| B1 | Current title | decision-gap | Phase 1 | Felton | resolved | Yes |", updated)
        self.assertIn("**Next unresolved blocker:** `/tt open B2`", updated)
        self.assertIn("Approved current decision.", updated)
        self.assertIn("Narrative must be preserved.", updated)
        self.assertIn("Preserve this too.", updated)
        self.assertNotIn("Stale decision text.", updated)
        updated_again = PLUGIN._updated_adjudication_content(updated, manifest)
        self.assertEqual(updated_again.count("## Blocker Register"), 1)
        self.assertIn("Narrative must be preserved.", updated_again)

    def test_validation_report_is_rewritten_with_canonical_warning_status(self):
        original = """# Validation Report

## Warnings Summary

| ID | Description | Status |
| --- | --- | --- |
| W3 | Configure error workflow | Open |
| W4 | Already corrected | **Resolved** |
| W7 | Update architecture | Open |

---

## Verdict

Pass With Warnings
"""
        manifest = {
            "warnings": [
                {"id": "W3", "description": "Configure error workflow", "status": "resolved", "verified": True},
                {"id": "W7", "description": "Update architecture", "status": "proposed", "verified": False},
            ],
            "sourceResolvedWarnings": [
                {"id": "W4", "description": "Already corrected", "sourceStatus": "**Resolved**"}
            ],
        }
        updated = PLUGIN._updated_validation_report_content(original, manifest, "tracker-note")
        self.assertIn("## Current Warning Follow-up", updated)
        self.assertIn("1 of 2 tracked warnings resolved and verified", updated)
        self.assertIn("| W3 | Configure error workflow | resolved | Yes |", updated)
        self.assertIn("| W4 | Already corrected | resolved before follow-up | Yes |", updated)
        self.assertIn("| W7 | Update architecture | proposed | No |", updated)
        self.assertNotIn("| W3 | Configure error workflow | Open |", updated)
        self.assertEqual(updated.count("TT-WARNING-FOLLOWUP:START"), 1)
        updated_again = PLUGIN._updated_validation_report_content(updated, manifest, "tracker-note")
        self.assertEqual(updated_again.count("TT-WARNING-FOLLOWUP:START"), 1)


if __name__ == "__main__":
    unittest.main()
