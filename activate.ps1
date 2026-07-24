[CmdletBinding()]
param(
    [string]$Project = "AI IT Agents",
    [string]$ProjectSlug = "ai-it-agents",
    [string]$ProjectDir = "AI IT Agents",
    [string]$TriliumProjectPath = "Planner/Projects/AI IT Agents",
    [string]$HermesHome = $(if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:LOCALAPPDATA "hermes" }),
    [string]$SourcePipelineDir = (Join-Path $HOME ".codex\triple-threat\pipelines\ai-it-agents"),
    [string]$InstalledCodexSkillDir = (Join-Path $HOME ".agents\skills\triple-threat"),
    [string]$HermesCommand,
    [switch]$SkipPluginEnable,
    [switch]$SkipDesktopShortcut
)

$ErrorActionPreference = "Stop"
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$runner = Join-Path $repo "hermes\skills\triple-threat-orchestrator\run.ps1"
$runtimeRoot = Join-Path $repo "hermes\skills\runtime"
$pluginSource = Join-Path $repo "hermes\plugins\triple-threat"
$pipelineRoot = Join-Path $HermesHome "pipelines"
$destinationPipeline = Join-Path $pipelineRoot $ProjectSlug
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $HermesHome "triple-threat-backups\$timestamp"
$stagingRoot = Join-Path $HermesHome (".triple-threat-cutover-{0}" -f [Guid]::NewGuid().ToString("N"))
$stagedPipeline = Join-Path $stagingRoot "pipeline"
$stagedSkills = Join-Path $stagingRoot "skills"
$stagedPlugin = Join-Path $stagingRoot "plugin"
$skillNames = @("triple-threat-orchestrator","claude-planner-reviewer","codex-builder","antigravity-reviewer")
$swaps = [Collections.Generic.List[object]]::new()

function Assert-NonemptyFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        throw "Required nonempty file is missing: $Path"
    }
}

function Copy-VerifiedDirectory([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Source directory is missing: $Source" }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
    foreach ($sourceFile in Get-ChildItem -LiteralPath $Source -File -Recurse -Force) {
        $relative = $sourceFile.FullName.Substring($Source.Length).TrimStart('\','/')
        $destinationFile = Join-Path $Destination $relative
        if (-not (Test-Path -LiteralPath $destinationFile -PathType Leaf)) {
            throw "Copied file is missing: $destinationFile"
        }
        if ((Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA256).Hash) {
            throw "Copy verification failed: $relative"
        }
    }
}

function Move-WithBackup([string]$Staged, [string]$Target, [string]$Backup) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Target))
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Backup))
    if (Test-Path -LiteralPath $Target) { Move-Item -LiteralPath $Target -Destination $Backup }
    try {
        Move-Item -LiteralPath $Staged -Destination $Target
    } catch {
        if (-not (Test-Path -LiteralPath $Target) -and (Test-Path -LiteralPath $Backup)) { Move-Item -LiteralPath $Backup -Destination $Target }
        throw
    }
    $swaps.Add([pscustomobject]@{ Target=$Target; Backup=$Backup })
}

function Disable-WithBackup([string]$Target, [string]$Backup) {
    if (-not (Test-Path -LiteralPath $Target)) { return }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Backup))
    Move-Item -LiteralPath $Target -Destination $Backup
    $swaps.Add([pscustomobject]@{ Target=$Target; Backup=$Backup })
}

function Rollback-Swaps {
    for ($index=$swaps.Count-1; $index -ge 0; $index--) {
        $swap=$swaps[$index]
        if (Test-Path -LiteralPath $swap.Target) { Remove-Item -LiteralPath $swap.Target -Recurse -Force }
        if (Test-Path -LiteralPath $swap.Backup) { Move-Item -LiteralPath $swap.Backup -Destination $swap.Target }
    }
}

try {
    Assert-NonemptyFile $runner
    Assert-NonemptyFile (Join-Path $pluginSource "plugin.yaml")
    Assert-NonemptyFile (Join-Path $pluginSource "__init__.py")
    foreach ($skillName in $skillNames) { Assert-NonemptyFile (Join-Path $runtimeRoot "$skillName\SKILL.md") }

    $scripts = @(Get-ChildItem -LiteralPath (Join-Path $repo "hermes") -Filter "*.ps1" -File -Recurse -Force)
    foreach ($script in $scripts) {
        $tokens=$null; $parseErrors=$null
        [Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$tokens,[ref]$parseErrors) | Out-Null
        if ($parseErrors.Count) { throw "PowerShell syntax failure in $($script.FullName): $($parseErrors[0].Message)" }
    }

    & $runner -Project $Project -ProjectSlug $ProjectSlug -ProjectDir $ProjectDir -TriliumProjectPath $TriliumProjectPath -ValidateOnly
    if ($LASTEXITCODE -ne 0) { throw "Hermes Triple-Threat ValidateOnly failed." }

    $sourceStatePath = Join-Path $SourcePipelineDir "state.json"
    $sourceManifestPath = Join-Path $SourcePipelineDir "blockers-round-1.json"
    $sourceValidationPath = Join-Path $SourcePipelineDir "validation-report-round-1.md"
    Assert-NonemptyFile $sourceStatePath
    Assert-NonemptyFile $sourceManifestPath
    Assert-NonemptyFile $sourceValidationPath
    $sourceState = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourceStatePath | ConvertFrom-Json
    $sourceManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourceManifestPath | ConvertFrom-Json
    if ($sourceState.project -ne $Project -or $sourceState.slug -ne $ProjectSlug) { throw "Source state does not belong to $Project/$ProjectSlug." }
    if ([int]$sourceState.currentStage -ne 8 -or $sourceState.status -ne "failed") { throw "Source state is not the expected failed Stage 8 state." }
    $blockers = @($sourceManifest.blockers)
    $unresolved = @($blockers | Where-Object { $_.status -ne "resolved" -or $_.verified -ne $true })
    if ($sourceManifest.status -ne "finalized" -or $blockers.Count -ne 8 -or $unresolved.Count -gt 0) { throw "Source blocker manifest is not the finalized eight-blocker workshop." }
    $sourceVerdict = @(Get-Content -Encoding UTF8 -LiteralPath $sourceValidationPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    if ($sourceVerdict.Count -ne 1 -or $sourceVerdict[0] -ne "Fail") { throw "Source validation report does not end with Fail." }

    [void][IO.Directory]::CreateDirectory($stagingRoot)
    Copy-VerifiedDirectory $SourcePipelineDir $stagedPipeline
    $stagedStatePath = Join-Path $stagedPipeline "state.json"
    $stateText = [IO.File]::ReadAllText($stagedStatePath)
    $escapedSourcePipeline = [IO.Path]::GetFullPath($SourcePipelineDir).Replace('\','\\')
    $escapedDestinationPipeline = [IO.Path]::GetFullPath($destinationPipeline).Replace('\','\\')
    $stateText = $stateText.Replace($escapedSourcePipeline, $escapedDestinationPipeline)
    [IO.File]::WriteAllText($stagedStatePath, $stateText, [Text.UTF8Encoding]::new($false))
    $stagedState = Get-Content -Raw -Encoding UTF8 -LiteralPath $stagedStatePath | ConvertFrom-Json
    if ($stagedState.projectDir -ne $ProjectDir -or $stagedState.triliumProjectPath -ne $TriliumProjectPath) { throw "Staged state metadata changed unexpectedly." }

    foreach ($skillName in $skillNames) {
        $stagedSkill = Join-Path $stagedSkills $skillName
        [void][IO.Directory]::CreateDirectory($stagedSkill)
        Copy-Item -LiteralPath (Join-Path $runtimeRoot "$skillName\SKILL.md") -Destination (Join-Path $stagedSkill "SKILL.md")
    }
    [void][IO.Directory]::CreateDirectory($stagedPlugin)
    Copy-Item -LiteralPath (Join-Path $pluginSource "plugin.yaml") -Destination $stagedPlugin
    Copy-Item -LiteralPath (Join-Path $pluginSource "__init__.py") -Destination $stagedPlugin

    $python = Join-Path $HermesHome "hermes-agent\venv\Scripts\python.exe"
    if (Test-Path -LiteralPath $python -PathType Leaf) {
        & $python -m py_compile (Join-Path $stagedPlugin "__init__.py")
        if ($LASTEXITCODE -ne 0) { throw "Triple-Threat Hermes plugin failed Python syntax validation." }
    }

    [void][IO.Directory]::CreateDirectory($backupRoot)
    Move-WithBackup $stagedPipeline $destinationPipeline (Join-Path $backupRoot "pipeline-$ProjectSlug")
    foreach ($skillName in $skillNames) {
        Move-WithBackup (Join-Path $stagedSkills $skillName) (Join-Path $HermesHome "skills\$skillName") (Join-Path $backupRoot "skills\$skillName")
    }
    Move-WithBackup $stagedPlugin (Join-Path $HermesHome "plugins\triple-threat") (Join-Path $backupRoot "plugins\triple-threat")

    $installedState = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $destinationPipeline "state.json") | ConvertFrom-Json
    $installedManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $destinationPipeline "blockers-round-1.json") | ConvertFrom-Json
    if ($installedState.status -ne "failed" -or [int]$installedState.currentStage -ne 8) { throw "Installed state did not preserve the Stage 8 failure." }
    if (@($installedManifest.blockers).Count -ne 8 -or $installedManifest.status -ne "finalized") { throw "Installed blocker manifest did not preserve all eight finalized blockers." }
    foreach ($skillName in $skillNames) {
        $sourceSkill = Join-Path $runtimeRoot "$skillName\SKILL.md"
        $installedSkill = Join-Path $HermesHome "skills\$skillName\SKILL.md"
        if ((Get-FileHash -LiteralPath $sourceSkill -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $installedSkill -Algorithm SHA256).Hash) { throw "Installed skill differs from source: $skillName" }
    }
    Disable-WithBackup $InstalledCodexSkillDir (Join-Path $backupRoot "retired-codex-skill\triple-threat")
    if (-not $SkipDesktopShortcut) {
        & (Join-Path $repo "hermes\enable-tt-desktop.ps1") -HermesHome $HermesHome -SkipPluginEnable:$SkipPluginEnable
        if ($LASTEXITCODE -ne 0) { throw "Hermes Desktop /tt shortcut installation failed." }
    }

    Write-Output "HERMES TRIPLE-THREAT CUTOVER PASS"
    Write-Output "Backup: $backupRoot"
    Write-Output "State preserved: Stage 8 failed, 8 of 8 blockers finalized and verified."
    Write-Output "The installed Codex coordinator skill was retired into the same backup when present."
    Write-Output "No specialist agent, deployment, installation, activation, commit, or push was performed."
    Write-Output "Restart Hermes, then use: /tt Remediate validation for $Project"
} catch {
    Rollback-Swaps
    throw
} finally {
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
}
