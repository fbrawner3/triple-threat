[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$patcher = Join-Path $repo "hermes\enable-tt-desktop.ps1"
$liveHermes = Join-Path $env:LOCALAPPDATA "hermes"
$liveServer = Join-Path $liveHermes "hermes-agent\acp_adapter\server.py"
$liveTuiServer = Join-Path $liveHermes "hermes-agent\tui_gateway\server.py"
$python = Join-Path $env:LOCALAPPDATA "codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
$testRoot = Join-Path $repo ("hermes-desktop-tt-test-{0}" -f [Guid]::NewGuid().ToString("N").Substring(0,10))
$server = Join-Path $testRoot "hermes-agent\acp_adapter\server.py"
$tuiServer = Join-Path $testRoot "hermes-agent\tui_gateway\server.py"
$skill = Join-Path $testRoot "skills\triple-threat-orchestrator\SKILL.md"

try {
    foreach ($directory in @((Split-Path -Parent $server),(Split-Path -Parent $tuiServer),(Split-Path -Parent $skill))) { [void][IO.Directory]::CreateDirectory($directory) }
    Copy-Item -LiteralPath $liveServer -Destination $server
    Copy-Item -LiteralPath $liveTuiServer -Destination $tuiServer
    Copy-Item -LiteralPath (Join-Path $repo "hermes\skills\runtime\triple-threat-orchestrator\SKILL.md") -Destination $skill
    $first = @(& $patcher -HermesHome $testRoot -PythonCommand $python -SkipPluginEnable) -join [Environment]::NewLine
    if ($first -notmatch "HERMES /TT FULL-WORKFLOW PLUGIN PASS") { throw "Full-workflow plugin update did not report success." }
    $patched = [IO.File]::ReadAllText($server)
    if ($patched -match "FNDHOME_TT_SHORTCUT_BEGIN") { throw "Superseded ACP shortcut was not removed." }
    $patchedTui = [IO.File]::ReadAllText($tuiServer)
    if (-not $patchedTui.Contains('return _ok(rid, {"type": "plugin", "output": str(result or "(no output)")}')) { throw "TUI slash.exec plugin output was not marked for visible transcript rendering." }
    if (-not $patchedTui.Contains("# FNDHOME_PLUGIN_PROGRESS_BEGIN") -or -not $patchedTui.Contains('"text": f"Working: {_cmd_label}..."') -or -not $patchedTui.Contains('"notification.clear"')) { throw "TUI plugin progress feedback was not installed." }
    $installedPlugin = [IO.File]::ReadAllText((Join-Path $testRoot "plugins\triple-threat\__init__.py"))
    if ($installedPlugin -notmatch 'remediate\\s\+validation' -or $installedPlugin -notmatch 'approve\\s\+') { throw "Full workflow commands were not installed." }
    $backupFiles = @(Get-ChildItem -LiteralPath (Join-Path $testRoot "triple-threat-backups") -Recurse -File)
    if (@($backupFiles | Where-Object Name -eq "server.py").Count -ne 1 -or @($backupFiles | Where-Object Name -eq "tui-gateway-server.py").Count -ne 1) { throw "Plugin update did not retain both Hermes server backups." }
    Write-Output "HERMES ISOLATED DESKTOP /TT PASS: one plugin owner, live Working feedback, visible final output, full workflow commands, Python validation, and backups."
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
