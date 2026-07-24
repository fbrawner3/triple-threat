[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$activation = Join-Path $repo "hermes\activate-triple-threat.ps1"
$sourcePipeline = Join-Path $HOME ".codex\triple-threat\pipelines\ai-it-agents"
$id = [Guid]::NewGuid().ToString("N").Substring(0,10)
$testRoot = Join-Path $repo "hermes-cutover-test-$id"
$hermesHome = Join-Path $testRoot "hermes-home"
$destination = Join-Path $hermesHome "pipelines\ai-it-agents"
$installedCodexSkill = Join-Path $testRoot "agents\skills\triple-threat"
$originalLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $testRoot "localappdata"
$env:TRIPLE_THREAT_CODEX_COMMAND = Join-Path $PSScriptRoot "fake-codex.ps1"
$env:TRIPLE_THREAT_CLAUDE_COMMAND = Join-Path $PSScriptRoot "fake-claude.ps1"
$env:TRIPLE_THREAT_AGY_COMMAND = Join-Path $PSScriptRoot "fake-agy.ps1"

try {
    [void][IO.Directory]::CreateDirectory($destination)
    [IO.File]::WriteAllText((Join-Path $destination "state.json"), '{"project":"old-hermes-state"}', [Text.UTF8Encoding]::new($false))
    foreach ($name in @("triple-threat-orchestrator","claude-planner-reviewer","codex-builder","antigravity-reviewer")) {
        $path=Join-Path $hermesHome "skills\$name"
        [void][IO.Directory]::CreateDirectory($path)
        [IO.File]::WriteAllText((Join-Path $path "SKILL.md"), "old $name", [Text.UTF8Encoding]::new($false))
    }
    $plugin=Join-Path $hermesHome "plugins\triple-threat"
    [void][IO.Directory]::CreateDirectory($plugin)
    [IO.File]::WriteAllText((Join-Path $plugin "plugin.yaml"), "old plugin", [Text.UTF8Encoding]::new($false))
    [void][IO.Directory]::CreateDirectory($installedCodexSkill)
    [IO.File]::WriteAllText((Join-Path $installedCodexSkill "SKILL.md"), "old codex coordinator", [Text.UTF8Encoding]::new($false))

    $output=@(& $activation -HermesHome $hermesHome -SourcePipelineDir $sourcePipeline -InstalledCodexSkillDir $installedCodexSkill -SkipPluginEnable -SkipDesktopShortcut) -join [Environment]::NewLine
    if($output -notmatch "HERMES TRIPLE-THREAT CUTOVER PASS"){throw "Cutover did not report success."}
    $state=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $destination "state.json") | ConvertFrom-Json
    $manifest=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $destination "blockers-round-1.json") | ConvertFrom-Json
    if($state.status -ne "failed" -or [int]$state.currentStage -ne 8){throw "Cutover did not preserve Stage 8 failure."}
    if($manifest.status -ne "finalized" -or @($manifest.blockers).Count -ne 8){throw "Cutover did not preserve eight finalized blockers."}
    $serialized=($state | ConvertTo-Json -Depth 12).Replace('\\','\')
    if($serialized.Contains([IO.Path]::GetFullPath($sourcePipeline))){throw "Cutover left Codex pipeline paths in saved state."}
    if(-not $serialized.Contains([IO.Path]::GetFullPath($destination))){throw "Cutover did not rewrite artifact paths to Hermes."}
    $backups=@(Get-ChildItem -LiteralPath (Join-Path $hermesHome "triple-threat-backups") -Directory)
    if($backups.Count -ne 1){throw "Expected exactly one cutover backup."}
    if(-not (Test-Path -LiteralPath (Join-Path $backups[0].FullName "pipeline-ai-it-agents\state.json"))){throw "Old Hermes state was not backed up."}
    if(Test-Path -LiteralPath $installedCodexSkill){throw "Installed Codex coordinator skill was not retired."}
    if(-not (Test-Path -LiteralPath (Join-Path $backups[0].FullName "retired-codex-skill\triple-threat\SKILL.md"))){throw "Installed Codex coordinator skill was not backed up."}
    Write-Output "HERMES ISOLATED CUTOVER PASS: stale-state backup, verified import, eight-blocker preservation, Codex-to-Hermes path rewrite, and skill/plugin replacement."
} finally {
    $env:LOCALAPPDATA=$originalLocalAppData
    foreach($name in @("TRIPLE_THREAT_CODEX_COMMAND","TRIPLE_THREAT_CLAUDE_COMMAND","TRIPLE_THREAT_AGY_COMMAND")){Remove-Item "Env:$name" -ErrorAction SilentlyContinue}
    if(Test-Path $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
