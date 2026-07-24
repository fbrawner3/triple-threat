[CmdletBinding()]
param(
    [string]$HermesHome = $(if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:LOCALAPPDATA "hermes" }),
    [string]$PythonCommand,
    [switch]$SkipPluginEnable
)

$ErrorActionPreference = "Stop"
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$runner = Join-Path $repo "hermes\skills\triple-threat-orchestrator\run.ps1"
$pluginSource = Join-Path $repo "hermes\plugins\triple-threat"
$pluginTarget = Join-Path $HermesHome "plugins\triple-threat"
$skillSource = Join-Path $repo "hermes\skills\runtime\triple-threat-orchestrator\SKILL.md"
$server = Join-Path $HermesHome "hermes-agent\acp_adapter\server.py"
$tuiServer = Join-Path $HermesHome "hermes-agent\tui_gateway\server.py"
$python = if ([string]::IsNullOrWhiteSpace($PythonCommand)) { Join-Path $HermesHome "hermes-agent\venv\Scripts\python.exe" } else { $PythonCommand }
$hermesCommand = Join-Path $HermesHome "hermes-agent\venv\Scripts\hermes.exe"
$skill = Join-Path $HermesHome "skills\triple-threat-orchestrator\SKILL.md"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $HermesHome "triple-threat-backups\tt-plugin-$timestamp"
$pluginBackup = Join-Path $backupRoot "plugin"
$skillBackup = Join-Path $backupRoot "SKILL.md"
$serverBackup = Join-Path $backupRoot "server.py"
$tuiServerBackup = Join-Path $backupRoot "tui-gateway-server.py"
$serverChanged = $false

foreach ($required in @(
    (Join-Path $pluginSource "plugin.yaml"),
    (Join-Path $pluginSource "__init__.py"),
    $skillSource,
    $server,
    $tuiServer,
    $python,
    $skill
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required Hermes file is missing: $required" }
}
if (-not $SkipPluginEnable -and -not (Test-Path -LiteralPath $hermesCommand -PathType Leaf)) { throw "Hermes command is missing: $hermesCommand" }

if (-not $SkipPluginEnable) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Project "AI IT Agents" -ProjectSlug "ai-it-agents" -ProjectDir "AI IT Agents" -TriliumProjectPath "Planner/Projects/AI IT Agents" -ValidateOnly
    if ($LASTEXITCODE -ne 0) { throw "Final Hermes Triple-Threat ValidateOnly failed; the plugin was not updated." }
}

[void][IO.Directory]::CreateDirectory($backupRoot)
if (Test-Path -LiteralPath $pluginTarget -PathType Container) { Copy-Item -LiteralPath $pluginTarget -Destination $pluginBackup -Recurse }
Copy-Item -LiteralPath $skill -Destination $skillBackup
Copy-Item -LiteralPath $server -Destination $serverBackup
Copy-Item -LiteralPath $tuiServer -Destination $tuiServerBackup

try {
    [void][IO.Directory]::CreateDirectory($pluginTarget)
    Copy-Item -LiteralPath (Join-Path $pluginSource "plugin.yaml") -Destination $pluginTarget -Force
    Copy-Item -LiteralPath (Join-Path $pluginSource "__init__.py") -Destination $pluginTarget -Force
    Copy-Item -LiteralPath $skillSource -Destination $skill -Force

    # Remove the superseded ACP-core workaround. The upgraded /tt plugin is now
    # the single command owner and covers both workflow and workshop operations.
    $serverText = [IO.File]::ReadAllText($server)
    $cleaned = [regex]::Replace(
        $serverText,
        '(?ms)^        # FNDHOME_TT_SHORTCUT_BEGIN\r?\n.*?^        # FNDHOME_TT_SHORTCUT_END\r?\n',
        ''
    )
    $cleaned = [regex]::Replace(
        $cleaned,
        '(?ms)^        \{\r?\n            "name": "tt",\r?\n            "description": "Run any FNDHome Triple-Threat workflow command",\r?\n            "input_hint": "project, stage, gate, validation, or blocker instruction",\r?\n        \},\r?\n',
        ''
    )
    if ($cleaned -ne $serverText) {
        [IO.File]::WriteAllText($server,$cleaned,[Text.UTF8Encoding]::new($false))
        $serverChanged = $true
    }

    # Hermes v0.18.2's TUI gateway labels plugin output on command.dispatch,
    # but not on slash.exec. The TUI therefore sends long /tt responses to its
    # pager instead of the visible transcript. Use the same explicit plugin
    # response shape on both routes.
    $tuiServerText = [IO.File]::ReadAllText($tuiServer)
    $oldTuiResponse = 'return _ok(rid, {"output": str(result or "(no output)")})'
    $newTuiResponse = 'return _ok(rid, {"type": "plugin", "output": str(result or "(no output)")})'
    $oldTuiCount = ([regex]::Matches($tuiServerText, [regex]::Escape($oldTuiResponse))).Count
    $newTuiCount = ([regex]::Matches($tuiServerText, [regex]::Escape($newTuiResponse))).Count
    if ($oldTuiCount -eq 1 -and $newTuiCount -eq 0) {
        $tuiServerText = $tuiServerText.Replace($oldTuiResponse, $newTuiResponse)
    } elseif ($oldTuiCount -ne 0 -or $newTuiCount -ne 1) {
        throw "Hermes TUI plugin-response compatibility point was not found unambiguously."
    }

    # A slash RPC runs on a worker thread, but the refreshed TUI leaves its
    # normal prompt visible and provides no busy indication. Emit a transient,
    # non-sensitive status notice before invoking any plugin command and clear
    # it only after the plugin returns. Include only the command and first action
    # word so record decisions and evidence never appear in the status line.
    $progressMarker = "# FNDHOME_PLUGIN_PROGRESS_BEGIN"
    if (-not $tuiServerText.Contains($progressMarker)) {
        $oldTuiBlock = @'
    if plugin_handler and resolve_plugin_command_result:
        try:
            result = resolve_plugin_command_result(plugin_handler(_cmd_arg))
            return _ok(rid, {"type": "plugin", "output": str(result or "(no output)")})
        except Exception as e:
            return _ok(rid, {"output": f"Plugin command error: {e}"})
'@
        $newTuiBlock = @'
    if plugin_handler and resolve_plugin_command_result:
        # FNDHOME_PLUGIN_PROGRESS_BEGIN
        _cmd_action = _cmd_arg.split(None, 1)[0] if _cmd_arg else ""
        _cmd_label = f"/{_cmd_base} {_cmd_action}".rstrip()
        _progress_key = f"plugin.slash.{_cmd_base}"
        _emit(
            "notification.show",
            sid,
            {
                "id": _progress_key,
                "key": _progress_key,
                "kind": "sticky",
                "level": "info",
                "ttl_ms": None,
                "text": f"Working: {_cmd_label}...",
            },
        )
        try:
            result = resolve_plugin_command_result(plugin_handler(_cmd_arg))
            return _ok(rid, {"type": "plugin", "output": str(result or "(no output)")})
        except Exception as e:
            return _ok(rid, {"type": "plugin", "output": f"Plugin command error: {e}"})
        finally:
            _emit("notification.clear", sid, {"key": _progress_key})
        # FNDHOME_PLUGIN_PROGRESS_END
'@
        $oldTuiBlockCount = ([regex]::Matches($tuiServerText, [regex]::Escape($oldTuiBlock))).Count
        if ($oldTuiBlockCount -ne 1) { throw "Hermes TUI plugin progress insertion point was not found unambiguously." }
        $tuiServerText = $tuiServerText.Replace($oldTuiBlock, $newTuiBlock)
    }
    if (([regex]::Matches($tuiServerText, [regex]::Escape($progressMarker))).Count -ne 1) { throw "Hermes TUI contains an invalid number of plugin progress hooks." }
    [IO.File]::WriteAllText($tuiServer, $tuiServerText, [Text.UTF8Encoding]::new($false))

    & $python -m py_compile (Join-Path $pluginTarget "__init__.py") $server $tuiServer
    if ($LASTEXITCODE -ne 0) { throw "The upgraded /tt plugin or restored Hermes ACP server failed Python syntax validation." }

    if (-not $SkipPluginEnable) {
        & $hermesCommand plugins enable triple-threat
        if ($LASTEXITCODE -ne 0) { throw "Hermes could not enable the complete /tt plugin." }
    }

    $installed = [IO.File]::ReadAllText((Join-Path $pluginTarget "__init__.py"))
    if (-not $installed.Contains('remediate\s+validation') -or -not $installed.Contains('approve\s+') -or -not $installed.Contains('_run_validation_warning') -or -not $installed.Contains('def _dispatch(')) { throw "The installed /tt plugin does not contain the full workflow, warning, and interactive-output surfaces." }
    if (-not [IO.File]::ReadAllText($skill).Contains('/tt record W3')) { throw "The installed Triple-Threat skill does not contain the validation warning workflow." }
    if ([IO.File]::ReadAllText($server).Contains("FNDHOME_TT_SHORTCUT_BEGIN")) { throw "The superseded ACP /tt workaround is still present." }
    if (-not [IO.File]::ReadAllText($tuiServer).Contains($newTuiResponse)) { throw "The Hermes TUI gateway does not preserve visible /tt plugin output." }
    if (-not [IO.File]::ReadAllText($tuiServer).Contains($progressMarker)) { throw "The Hermes TUI gateway does not show plugin progress." }

    $pipeline = Join-Path $HermesHome "pipelines\ai-it-agents"
    $statePath = Join-Path $pipeline "state.json"
    $warningPath = Join-Path $pipeline "validation-warnings-round-1.json"
    if ((Test-Path -LiteralPath $statePath -PathType Leaf) -and -not (Test-Path -LiteralPath $warningPath -PathType Leaf)) {
        $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json
        $validationPath = Join-Path $pipeline "validation-report-round-1.md"
        if ($state.status -eq "complete" -and (Test-Path -LiteralPath $validationPath -PathType Leaf)) {
            $verdict = @(Get-Content -Encoding UTF8 -LiteralPath $validationPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
            if ($verdict.Count -eq 1 -and $verdict[0] -eq "Pass With Warnings") {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Project "AI IT Agents" -ProjectSlug "ai-it-agents" -ProjectDir "AI IT Agents" -TriliumProjectPath "Planner/Projects/AI IT Agents" -ValidationWarningAction initialize -TransactionId ([Guid]::NewGuid().ToString("D"))
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $warningPath -PathType Leaf)) { throw "AI IT Agents validation warning initialization failed." }
            }
        }
    }
} catch {
    if (Test-Path -LiteralPath $pluginTarget) { Remove-Item -LiteralPath $pluginTarget -Recurse -Force }
    if (Test-Path -LiteralPath $pluginBackup) { Copy-Item -LiteralPath $pluginBackup -Destination $pluginTarget -Recurse }
    Copy-Item -LiteralPath $skillBackup -Destination $skill -Force
    Copy-Item -LiteralPath $serverBackup -Destination $server -Force
    Copy-Item -LiteralPath $tuiServerBackup -Destination $tuiServer -Force
    throw
}

Write-Output "HERMES /TT FULL-WORKFLOW PLUGIN PASS"
Write-Output "Backup: $backupRoot"
Write-Output "The complete /tt plugin is the only Triple-Threat command owner."
Write-Output "Hermes TUI plugin responses are rendered in the visible transcript instead of the hidden pager path."
Write-Output "Hermes TUI shows a Working status while /tt commands are running."
Write-Output "Validation warning follow-up is installed and initialized when the completed report contains open warnings."
Write-Output "Restart Hermes Desktop once, then use: /tt warnings"
