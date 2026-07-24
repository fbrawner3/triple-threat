[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$ProjectSlug,
    [Parameter(Mandatory)][string]$ProjectDir,
    [Parameter(Mandatory)][string]$TriliumProjectPath,
    [ValidateRange(1,8)][int]$FromStage = 1,
    [ValidateRange(1,8)][int]$ToStage = 8,
    [ValidateSet("post-architecture","post-adjudication","post-decision-register","post-implementation","post-validation")][string]$ApproveGate,
    [ValidateSet("work","show","open","research","brief","resume","create","define","record","verify","finalize")][string]$WorkshopAction,
    [ValidateSet("initialize","reconcile","show","open","record","verify")][string]$ValidationWarningAction,
    [string]$BlockerId,
    [string]$BlockerTitle,
    [string]$BlockerQuestion,
    [string]$WhyBlocking,
    [string]$Recommendation,
    [string[]]$Alternatives,
    [ValidateSet("yes","no")][string]$EvidenceRequired = "yes",
    [string]$Decision,
    [string]$Evidence,
    [ValidatePattern('^W[0-9]+$')][string]$WarningId,
    [string]$WarningDecision,
    [string]$WarningEvidence,
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$TransactionId,
    [switch]$RemediateValidation,
    [switch]$PreflightOnly,
    [switch]$ValidateOnly
)
. (Join-Path $PSScriptRoot "..\pipeline-common.ps1")
if ($FromStage -gt $ToStage) { throw "FromStage cannot exceed ToStage." }
$repo = Get-RepoRoot
$work = Get-SafePath $repo $ProjectDir
if (-not (Test-Path -LiteralPath $work -PathType Container)) { throw "Project directory does not exist: $work" }
if ($ValidateOnly) {
    $requiredScripts = @(Get-ChildItem -LiteralPath (Join-Path $repo "hermes") -Filter "*.ps1" -File -Recurse -Force)
    foreach ($script in $requiredScripts) {
        $scriptPath = if ($script -is [IO.FileInfo]) { $script.FullName } else { [string]$script }
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Missing pipeline script: $scriptPath" }
        $tokens=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $scriptPath),[ref]$tokens,[ref]$errors) | Out-Null
        if ($errors.Count) { throw "PowerShell syntax failure in ${scriptPath}: $($errors[0].Message)" }
    }
    $codexTool = Get-Tool "codex" @("%APPDATA%\npm\codex.cmd")
    $claudeTool = Get-Tool "claude" @("%APPDATA%\npm\claude.cmd")
    $agyTool = Get-Tool "agy" @("%LOCALAPPDATA%\agy\bin\agy.exe")
    Test-NativeTool "codex" $codexTool @("exec", "--disable", "plugins", "--help")
    Test-NativeTool "claude" $claudeTool @("--version")
    Test-NativeTool "agy" $agyTool @("--help")
    Write-Output "Validation passed: every Hermes Triple-Threat PowerShell script parses, the existing project path is inside the repository, and codex/claude/agy execute successfully. No agent was invoked."
    exit 0
}
$pipe = Get-HermesPipelineRoot $ProjectSlug -CreateDirectory:(-not $PreflightOnly)
$legacyPipe = Join-Path $work ".pipeline"
if (-not $PreflightOnly -and (Test-Path -LiteralPath (Join-Path $legacyPipe "state.json") -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $pipe "state.json") -PathType Leaf)) {
    Write-Output "Moving the saved pipeline state out of the repository."
    foreach ($item in Get-ChildItem -LiteralPath $legacyPipe -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $pipe $item.Name) -Recurse -Force
    }
    foreach ($source in Get-ChildItem -LiteralPath $legacyPipe -Recurse -File -Force) {
        $relative = $source.FullName.Substring($legacyPipe.Length).TrimStart('\','/')
        $destination = Join-Path $pipe $relative
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw "Pipeline migration missed $relative" }
        if ((Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash) { throw "Pipeline migration verification failed for $relative" }
    }
    Remove-Item -LiteralPath $legacyPipe -Recurse -Force
    Write-Output "Saved pipeline state is now in Hermes local storage."
}
$stateFile = Join-Path $pipe "state.json"
$log = Join-Path $pipe ("run-log-{0}.md" -f (Get-Date -Format yyyy-MM-dd))
$blockerFile = $null
$warningFile = $null
function Get-BlockerManifest {
    if (-not (Test-Path -LiteralPath $blockerFile -PathType Leaf)) { throw "The Stage 5 blocker manifest is missing: $blockerFile" }
    try { $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $blockerFile | ConvertFrom-Json } catch { throw "The blocker manifest is invalid JSON: $blockerFile" }
    if ($manifest.project -ne $Project -or [int]$manifest.round -ne [int]$state.round) { throw "The blocker manifest belongs to a different project or round." }
    if ($manifest.PSObject.Properties.Name -notcontains "blockers") { throw "The blocker manifest has no blockers collection." }
    return $manifest
}
function Save-BlockerManifest($Manifest) { Save-Json $Manifest $blockerFile }
function Get-ValidationWarningManifest {
    if (-not (Test-Path -LiteralPath $warningFile -PathType Leaf)) { throw "The validation warning manifest is missing: $warningFile" }
    try { $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $warningFile | ConvertFrom-Json } catch { throw "The validation warning manifest is invalid JSON: $warningFile" }
    if ($manifest.project -ne $Project -or [int]$manifest.round -ne [int]$state.round) { throw "The validation warning manifest belongs to a different project or round." }
    if ($manifest.PSObject.Properties.Name -notcontains "warnings") { throw "The validation warning manifest has no warnings collection." }
    return $manifest
}
function Save-ValidationWarningManifest($Manifest) { Save-Json $Manifest $warningFile }
function Get-ValidationWarningRows {
    $validationPath = Join-Path $pipe ("validation-report-round-{0}.md" -f $state.round)
    Assert-Output $validationPath
    $reportLines = @(Get-Content -Encoding UTF8 -LiteralPath $validationPath)
    $verdict = @($reportLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    if ($verdict.Count -ne 1 -or $verdict[0] -ne "Pass With Warnings") { throw "Validation warnings require a report ending with Pass With Warnings." }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($line in $reportLines) {
        if ($line -notmatch '^\|\s*(W[0-9]+)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*$') { continue }
        $sourceStatus = $Matches[3].Trim()
        $normalizedStatus = ($sourceStatus -replace '[*_`~]', '').Trim()
        $rows.Add([pscustomobject][ordered]@{
            id=$Matches[1].ToUpperInvariant(); description=$Matches[2].Trim(); sourceStatus=$sourceStatus
            isOpen=($normalizedStatus -notmatch '^(?i:resolved|closed)$')
        })
    }
    $ids = @($rows | ForEach-Object { $_.id })
    if (($ids | Sort-Object -Unique).Count -ne $ids.Count) { throw "The validation report contains duplicate warning IDs." }
    return @($rows)
}
function Initialize-ValidationWarningManifest([switch]$Force) {
    $validationPath = Join-Path $pipe ("validation-report-round-{0}.md" -f $state.round)
    Assert-Output $validationPath
    $reportHash = (Get-FileHash -LiteralPath $validationPath -Algorithm SHA256).Hash
    if ((Test-Path -LiteralPath $warningFile -PathType Leaf) -and -not $Force) {
        $existing = Get-ValidationWarningManifest
        if ($existing.validationReportSha256 -eq $reportHash) { return $existing }
        throw "The validation report changed after the warning manifest was created. Run validation again before working warnings."
    }
    $reportRows = @(Get-ValidationWarningRows)
    $warnings = [Collections.Generic.List[object]]::new()
    foreach ($row in @($reportRows | Where-Object { $_.isOpen })) {
        $warnings.Add([pscustomobject][ordered]@{
            id=$row.id; description=$row.description; sourceStatus=$row.sourceStatus; status="open"
            decision=$null; evidence=$null; evidenceRequired=$true; verified=$false
            approvedBy=$null; approvedAt=$null
        })
    }
    if ($warnings.Count -eq 0) { throw "The Pass With Warnings report contains no open W-numbered rows in its Warnings Summary table." }
    $manifest = [pscustomobject][ordered]@{
        project=$Project; slug=$ProjectSlug; round=[int]$state.round; status="open"
        validationReport=$validationPath; validationReportSha256=$reportHash
        warnings=@($warnings)
        sourceResolvedWarnings=@($reportRows | Where-Object { -not $_.isOpen } | ForEach-Object { [pscustomobject][ordered]@{id=$_.id;description=$_.description;sourceStatus=$_.sourceStatus} })
        createdAt=(Get-Date).ToString("o"); finalizedAt=$null
    }
    Save-ValidationWarningManifest $manifest
    return $manifest
}
function Reconcile-ValidationWarningManifest {
    $manifest = Get-ValidationWarningManifest
    $reportRows = @(Get-ValidationWarningRows)
    $openRows = @($reportRows | Where-Object { $_.isOpen })
    if ($openRows.Count -eq 0) { throw "The Pass With Warnings report contains no open W-numbered rows to reconcile." }
    $reconciled = [Collections.Generic.List[object]]::new()
    foreach ($row in $openRows) {
        $matches = @($manifest.warnings | Where-Object { $_.id -eq $row.id })
        if ($matches.Count -gt 1) { throw "The warning manifest contains duplicate warning ID $($row.id)." }
        if ($matches.Count -eq 1) {
            $item = $matches[0]
            $item.description = $row.description
            $item.sourceStatus = $row.sourceStatus
            $reconciled.Add($item)
        } else {
            $reconciled.Add([pscustomobject][ordered]@{
                id=$row.id; description=$row.description; sourceStatus=$row.sourceStatus; status="open"
                decision=$null; evidence=$null; evidenceRequired=$true; verified=$false
                approvedBy=$null; approvedAt=$null
            })
        }
    }
    $manifest.warnings = @($reconciled)
    $sourceResolved = @($reportRows | Where-Object { -not $_.isOpen } | ForEach-Object { [pscustomobject][ordered]@{id=$_.id;description=$_.description;sourceStatus=$_.sourceStatus} })
    $manifest | Add-Member -NotePropertyName sourceResolvedWarnings -NotePropertyValue $sourceResolved -Force
    $remaining = @($manifest.warnings | Where-Object { $_.status -ne "resolved" -or $_.verified -ne $true })
    if ($remaining.Count -eq 0) { $manifest.status="resolved"; $manifest.finalizedAt=(Get-Date).ToString("o") }
    else { $manifest.status="open"; $manifest.finalizedAt=$null }
    Save-ValidationWarningManifest $manifest
    return $manifest
}
function Get-ValidationWarning($Manifest, [string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id)) { throw "WarningId is required for validation warning action '$ValidationWarningAction'." }
    $matches = @($Manifest.warnings | Where-Object { $_.id -eq $Id })
    if ($matches.Count -ne 1) { throw "Unknown validation warning ID: $Id" }
    return $matches[0]
}
function Write-ValidationWarning($Item) {
    Write-Output "$($Item.id) - $($Item.description)"
    Write-Output "Status: $($Item.status)"
    Write-Output "Evidence required: $($Item.evidenceRequired)"
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.decision)) { Write-Output "Recorded resolution: $($Item.decision)" }
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.evidence)) { Write-Output "Recorded evidence: $($Item.evidence)" }
}
function Write-ValidationWarningSummary($Manifest) {
    $warnings = @($Manifest.warnings)
    $resolved = @($warnings | Where-Object { $_.status -eq "resolved" -and $_.verified -eq $true })
    Write-Output "Validation warnings: $($resolved.Count) of $($warnings.Count) resolved and verified."
    foreach ($item in $warnings) { Write-Output ("- {0}: {1} [{2}]" -f $item.id, $item.description, $item.status) }
    $next = @($warnings | Where-Object { $_.status -ne "resolved" -or $_.verified -ne $true } | Select-Object -First 1)
    if ($next.Count -gt 0) { Write-Output "Next: /tt open $($next[0].id)" } else { Write-Output "All validation warnings are resolved and verified. The completed run remains complete; nothing was deployed or activated." }
}
function Complete-CoordinatorTransaction(
    [Parameter(Mandatory)][string]$Action,
    [string]$TransactionBlockerId,
    [string]$TransactionWarningId,
    [string]$Gate,
    [Parameter(Mandatory)][string]$Result
) {
    $receipt = [pscustomobject][ordered]@{
        id = if ([string]::IsNullOrWhiteSpace($TransactionId)) { [Guid]::NewGuid().ToString("D") } else { $TransactionId.ToLowerInvariant() }
        action = $Action
        blockerId = if ([string]::IsNullOrWhiteSpace($TransactionBlockerId)) { $null } else { $TransactionBlockerId }
        warningId = if ([string]::IsNullOrWhiteSpace($TransactionWarningId)) { $null } else { $TransactionWarningId }
        gate = if ([string]::IsNullOrWhiteSpace($Gate)) { $null } else { $Gate }
        projectSlug = $ProjectSlug
        round = [int]$state.round
        result = $Result
        manifestSha256 = if (Test-Path -LiteralPath $blockerFile -PathType Leaf) { (Get-FileHash -LiteralPath $blockerFile -Algorithm SHA256).Hash } else { $null }
        warningManifestSha256 = if (Test-Path -LiteralPath $warningFile -PathType Leaf) { (Get-FileHash -LiteralPath $warningFile -Algorithm SHA256).Hash } else { $null }
        timestamp = (Get-Date).ToString("o")
    }
    $state | Add-Member -NotePropertyName lastTransaction -NotePropertyValue $receipt -Force
    Save-Json $state $stateFile
    Add-RunLog $log ("Transaction {0}: {1} ({2})." -f $receipt.id, $Action, $Result)
    Write-Output ("TRIPLE_THREAT_TRANSACTION_RECEIPT: {0}" -f ($receipt | ConvertTo-Json -Compress))
}
function Get-WorkshopBlocker($Manifest, [string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id)) { throw "BlockerId is required for workshop action '$WorkshopAction'." }
    $matches = @($Manifest.blockers | Where-Object { $_.id -eq $Id })
    if ($matches.Count -ne 1) { throw "Unknown blocker ID: $Id" }
    return $matches[0]
}
function Write-WorkshopSummary($Manifest) {
    $blockers = @($Manifest.blockers)
    $resolved = @($blockers | Where-Object { $_.status -eq "resolved" -and $_.verified -eq $true })
    Write-Output "Adjudication workshop: $($resolved.Count) of $($blockers.Count) blockers resolved and verified."
    foreach ($item in $blockers) { Write-Output ("- {0}: {1} [{2}]" -f $item.id, $item.title, $item.status) }
    $next = @($blockers | Where-Object { $_.status -ne "resolved" -or $_.verified -ne $true } | Select-Object -First 1)
    if ($next.Count -gt 0) { Write-Output "Next: /tt open $($next[0].id)" } else { Write-Output "Next: /tt finalize adjudication" }
}
function Write-WorkshopBlocker($Item) {
    Write-Output "$($Item.id) - $($Item.title)"
    Write-Output "Status: $($Item.status)"
    Write-Output "Question: $($Item.question)"
    Write-Output "Why it blocks: $($Item.whyBlocking)"
    Write-Output "Recommendation: $($Item.recommendation)"
    Write-Output "Alternatives: $(@($Item.alternatives) -join '; ')"
    Write-Output "Evidence required: $($Item.evidenceRequired)"
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.decision)) { Write-Output "Recorded decision: $($Item.decision)" }
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.evidence)) { Write-Output "Recorded evidence: $($Item.evidence)" }
}
function Write-ApprovalInstructions([string]$Gate, [int]$NextStage) {
    $escapedProject = $Project.Replace('"','`"')
    $escapedSlug = $ProjectSlug.Replace('"','`"')
    $escapedDir = $ProjectDir.Replace('"','`"')
    $escapedTriliumPath = $TriliumProjectPath.Replace('"','`"')
    Write-Output "The Triple-Threat workflow is paused, not complete."
    if ($Gate -eq "post-validation") {
        Write-Output "All eight stages have passed. Nothing has been deployed, installed, committed, pushed, or activated."
        Write-Output "When ready, use command: `"Finalize validated runbook`" to accept the handoff and complete the workflow."
    } else {
        Write-Output "Next stage: $NextStage. Nothing has been deployed, installed, committed, pushed, or activated."
        Write-Output "When ready, use command: `"Approve $Gate`" to continue."
    }
    Write-Output "Continuation command:"
    Write-Output "powershell.exe -NoProfile -ExecutionPolicy Bypass -File hermes/skills/triple-threat-orchestrator/run.ps1 -Project `"$escapedProject`" -ProjectSlug `"$escapedSlug`" -ProjectDir `"$escapedDir`" -TriliumProjectPath `"$escapedTriliumPath`" -FromStage 1 -ToStage 8 -ApproveGate $Gate"
}
if (Test-Path $stateFile) {
    $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $stateFile | ConvertFrom-Json
    if ($state.slug -ne $ProjectSlug) { throw "State belongs to slug '$($state.slug)', not '$ProjectSlug'." }
    $stateNeedsUpdate = $false
    if ($state.PSObject.Properties.Name -contains "project" -and $state.project -ne $Project) { throw "Saved state project is '$($state.project)', not '$Project'." }
    if ($state.PSObject.Properties.Name -notcontains "project") { $state | Add-Member -NotePropertyName project -NotePropertyValue $Project; $stateNeedsUpdate = $true }
    if ($state.PSObject.Properties.Name -contains "projectDir" -and $state.projectDir -ne $ProjectDir) { throw "Saved state project directory is '$($state.projectDir)', not '$ProjectDir'." }
    if ($state.PSObject.Properties.Name -notcontains "projectDir") { $state | Add-Member -NotePropertyName projectDir -NotePropertyValue $ProjectDir -Force; $stateNeedsUpdate = $true }
    if ($state.PSObject.Properties.Name -contains "triliumProjectPath" -and $state.triliumProjectPath -ne $TriliumProjectPath) { throw "Saved state Trilium path is '$($state.triliumProjectPath)', not '$TriliumProjectPath'." }
    if ($state.PSObject.Properties.Name -notcontains "triliumProjectPath") { $state | Add-Member -NotePropertyName triliumProjectPath -NotePropertyValue $TriliumProjectPath -Force; $stateNeedsUpdate = $true }
    if ($state.PSObject.Properties.Name -notcontains "artifacts") { $state | Add-Member -NotePropertyName artifacts -NotePropertyValue ([pscustomobject]@{}); $stateNeedsUpdate = $true }
    if ($stateNeedsUpdate -and -not $PreflightOnly) { Save-Json $state $stateFile }
} else {
    if ($PreflightOnly) { throw "Cannot preflight a workflow with no saved state: $stateFile" }
    $state = [pscustomobject]@{ project=$Project; slug=$ProjectSlug; projectDir=$ProjectDir; triliumProjectPath=$TriliumProjectPath; round=1; currentStage=$FromStage; status="ready"; pendingGate=$null; artifacts=[pscustomobject]@{}; approvals=@(); lastError=$null }
    Set-Content $log "# Triple-Threat Run Log - $Project" -Encoding UTF8
    Save-Json $state $stateFile
}
$blockerFile = Join-Path $pipe ("blockers-round-{0}.json" -f $state.round)
$warningFile = Join-Path $pipe ("validation-warnings-round-{0}.json" -f $state.round)
$artifactCandidates = [ordered]@{
    stage1 = @([pscustomobject]@{ files=@("00-project-design.md") })
    stage2 = @(
        [pscustomobject]@{ files=@("architecture.md", "architecture-summary.md") },
        [pscustomobject]@{ files=@("architecture-summary.md") }
    )
    stage3 = @([pscustomobject]@{ files=@("codex-review-round-$($state.round).md") })
    stage4 = @([pscustomobject]@{ files=@("ag-review-round-$($state.round).md") })
    stage5 = @(
        [pscustomobject]@{ files=@("blockers-round-$($state.round).json", "adjudication-receipt-round-$($state.round).md") },
        [pscustomobject]@{ files=@("blockers-round-$($state.round).json", "adjudication-summary-round-$($state.round).md") }
    )
    stage6 = @([pscustomobject]@{ files=@("decision-register-round-$($state.round).md", "decision-register-receipt-round-$($state.round).md") })
    stage7 = @([pscustomobject]@{ files=@("implementation-receipt-round-$($state.round).md", "IMPLEMENTATION-RUNBOOK.md") })
    stage8 = @([pscustomobject]@{ files=@("validation-report-round-$($state.round).md") })
}
$backfilledArtifacts = $false
foreach ($stageName in $artifactCandidates.Keys) {
    $recordedArtifactStages = @($state.artifacts.PSObject.Properties | ForEach-Object { $_.Name })
    if ($recordedArtifactStages -contains $stageName) { continue }
    foreach ($candidateSet in $artifactCandidates[$stageName]) {
        $candidatePaths = @($candidateSet.files | ForEach-Object { if ($_ -eq "IMPLEMENTATION-RUNBOOK.md") { Join-Path $work $_ } else { Join-Path $pipe $_ } })
        $completeSet = @($candidatePaths | Where-Object { (Test-Path -LiteralPath $_ -PathType Leaf) -and (Get-Item -LiteralPath $_).Length -gt 0 }).Count -eq $candidatePaths.Count
        if ($completeSet) {
            $state.artifacts | Add-Member -NotePropertyName $stageName -NotePropertyValue $candidatePaths -Force
            $backfilledArtifacts = $true
            break
        }
    }
}
if ($backfilledArtifacts -and -not $PreflightOnly) { Save-Json $state $stateFile }
if ($PreflightOnly) {
    $stage = [int]$state.currentStage
    if ($stage -gt 8) { Write-Output "Preflight passed: all eight stages are complete; no specialist stage remains."; exit 0 }
    $selectedArchitecture = $null
    if ($stage -in @(3,4,5,7,8)) { $selectedArchitecture = Resolve-ArchitectureHandoff $pipe "architecture.md"; Assert-Output $selectedArchitecture }
    switch ($stage) {
        2 { Assert-Output (Join-Path $pipe "00-project-design.md") }
        5 {
            Assert-Output (Join-Path $pipe "codex-review-round-$($state.round).md")
            Assert-Output (Join-Path $pipe "ag-review-round-$($state.round).md")
        }
        { $_ -in @(6,7) } {
            $manifest = Get-BlockerManifest
            $unresolved = @($manifest.blockers | Where-Object { $_.status -ne "resolved" -or $_.verified -ne $true })
            if ($manifest.status -ne "finalized" -or $unresolved.Count -gt 0) { throw "Stage $stage requires a finalized blocker manifest with every blocker resolved and verified." }
            if ($stage -eq 7) { Assert-Output (Join-Path $pipe "decision-register-round-$($state.round).md") }
        }
        8 {
            Assert-Output (Join-Path $pipe "decision-register-round-$($state.round).md")
            Assert-Output (Join-Path $work "IMPLEMENTATION-RUNBOOK.md")
        }
    }
    if ($stage -in @(1,2,5,6,8)) {
        $tool = Get-Tool "claude" @("%APPDATA%\npm\claude.cmd")
        Test-NativeTool "claude" $tool @("--version")
    } elseif ($stage -in @(3,7)) {
        $tool = Get-Tool "codex" @("%APPDATA%\npm\codex.cmd")
        Test-NativeTool "codex" $tool @("exec", "--disable", "plugins", "--help")
    } elseif ($stage -eq 4) {
        $tool = Get-Tool "agy" @("%LOCALAPPDATA%\agy\bin\agy.exe")
        Test-NativeTool "agy" $tool @("--help")
    }
    Write-Output "Preflight passed for Stage $stage. No agent was invoked and saved workflow state was not changed."
    if ($selectedArchitecture) { Write-Output "Architecture input: $selectedArchitecture" }
    exit 0
}
if (-not [string]::IsNullOrWhiteSpace($TransactionId) -and $state.PSObject.Properties.Name -contains "lastTransaction" -and $state.lastTransaction.id -eq $TransactionId.ToLowerInvariant()) {
    Write-Output ("TRIPLE_THREAT_TRANSACTION_RECEIPT: {0}" -f ($state.lastTransaction | ConvertTo-Json -Compress))
    Write-Output "Transaction was already committed; no action was repeated."
    exit 0
}
if ($ValidationWarningAction) {
    if ($state.artifacts.PSObject.Properties.Name -notcontains "stage8") { throw "Validation warnings are unavailable until Stage 8 has produced a report." }
    $manifest = if ($ValidationWarningAction -eq "initialize") { Initialize-ValidationWarningManifest } else { Get-ValidationWarningManifest }
    switch ($ValidationWarningAction) {
        "initialize" {
            Add-RunLog $log "Initialized the validation warning follow-up manifest."
            Complete-CoordinatorTransaction -Action "initialize-warnings" -Result "warning-follow-up-ready"
            Write-ValidationWarningSummary $manifest
            exit 0
        }
        "reconcile" {
            $manifest = Reconcile-ValidationWarningManifest
            Add-RunLog $log "Reconciled validation warnings against the Stage 8 Warnings Summary statuses."
            Complete-CoordinatorTransaction -Action "reconcile-warnings" -Result "warning-follow-up-reconciled"
            Write-ValidationWarningSummary $manifest
            exit 0
        }
        "show" {
            Write-ValidationWarningSummary $manifest
            exit 0
        }
        "open" {
            Write-ValidationWarning (Get-ValidationWarning $manifest $WarningId)
            exit 0
        }
        "record" {
            if ([string]::IsNullOrWhiteSpace($WarningDecision)) { throw "WarningDecision is required for validation warning action 'record'." }
            $item = Get-ValidationWarning $manifest $WarningId
            $item.decision=$WarningDecision.Trim()
            if (-not [string]::IsNullOrWhiteSpace($WarningEvidence)) { $item.evidence=$WarningEvidence.Trim() }
            $item.verified=$false; $item.approvedBy=$null; $item.approvedAt=$null
            $item.status=if ($item.evidenceRequired -eq $true -and [string]::IsNullOrWhiteSpace([string]$item.evidence)) { "awaiting-evidence" } else { "proposed" }
            $manifest.status="open"; $manifest.finalizedAt=$null
            Save-ValidationWarningManifest $manifest
            Add-RunLog $log "Recorded a proposed resolution for validation warning $WarningId."
            Complete-CoordinatorTransaction -Action "record-warning" -TransactionWarningId $WarningId -Result $item.status
            Write-ValidationWarning $item
            if ($item.status -eq "awaiting-evidence") { Write-Output "Evidence is still required. Use: /tt record $WarningId <resolution> --evidence <evidence>" } else { Write-Output "When the resolution is correct, use: /tt verify $WarningId" }
            exit 0
        }
        "verify" {
            $item = Get-ValidationWarning $manifest $WarningId
            if ([string]::IsNullOrWhiteSpace([string]$item.decision)) { throw "Record a resolution for $WarningId before verification." }
            if ($item.evidenceRequired -eq $true -and [string]::IsNullOrWhiteSpace([string]$item.evidence)) { throw "$WarningId requires evidence before verification." }
            $item.status="resolved"; $item.verified=$true; $item.approvedBy="Felton"; $item.approvedAt=(Get-Date).ToString("o")
            $remaining = @($manifest.warnings | Where-Object { $_.status -ne "resolved" -or $_.verified -ne $true })
            if ($remaining.Count -eq 0) { $manifest.status="resolved"; $manifest.finalizedAt=(Get-Date).ToString("o") }
            Save-ValidationWarningManifest $manifest
            Add-RunLog $log "Resolved and verified validation warning $WarningId."
            Complete-CoordinatorTransaction -Action "verify-warning" -TransactionWarningId $WarningId -Result "resolved-and-verified"
            Write-Output "$WarningId is resolved and verified."
            Write-ValidationWarningSummary $manifest
            exit 0
        }
    }
}
if ($WorkshopAction) {
    $manifest = Get-BlockerManifest
    switch ($WorkshopAction) {
        "work" {
            $state.status="awaiting-workshop"; $state.pendingGate="post-adjudication"; Save-Json $state $stateFile
            Complete-CoordinatorTransaction -Action "work" -Result "workshop-ready"
            Write-WorkshopSummary $manifest
            exit 0
        }
        "show" {
            Write-WorkshopSummary $manifest
            exit 0
        }
        { $_ -in @("open","resume") } {
            Write-WorkshopBlocker (Get-WorkshopBlocker $manifest $BlockerId)
            exit 0
        }
        "research" {
            $item = Get-WorkshopBlocker $manifest $BlockerId
            $item.status="researching"; $item.verified=$false; $item.approvedBy=$null; $item.approvedAt=$null; Save-BlockerManifest $manifest
            $state.status="awaiting-workshop"; Save-Json $state $stateFile; Add-RunLog $log "Workshop blocker $BlockerId set to researching."
            Complete-CoordinatorTransaction -Action "research" -TransactionBlockerId $BlockerId -Result "researching"
            Write-Output "$BlockerId is now researching. Next: /tt brief $BlockerId"
            exit 0
        }
        "brief" {
            $item = Get-WorkshopBlocker $manifest $BlockerId
            Write-Output "Research brief for $BlockerId"
            Write-WorkshopBlocker $item
            Write-Output "Return with: /tt record $BlockerId <decision>"
            exit 0
        }
        "create" {
            if ([string]::IsNullOrWhiteSpace($BlockerTitle)) { throw "BlockerTitle is required for workshop action 'create'." }
            $numbers = @($manifest.blockers | ForEach-Object { if ([string]$_.id -match '^B([0-9]+)$') { [int]$Matches[1] } })
            $nextNumber = if ($numbers.Count -gt 0) { ([int](($numbers | Measure-Object -Maximum).Maximum)) + 1 } else { 1 }
            $newId = "B$nextNumber"
            $detailsComplete = -not [string]::IsNullOrWhiteSpace($BlockerQuestion) -and -not [string]::IsNullOrWhiteSpace($WhyBlocking) -and -not [string]::IsNullOrWhiteSpace($Recommendation)
            $newBlocker = [pscustomobject][ordered]@{
                id=$newId; title=$BlockerTitle.Trim(); question=if ([string]::IsNullOrWhiteSpace($BlockerQuestion)) { $null } else { $BlockerQuestion.Trim() }
                type="workshop-discovery"; sourceFindingIds=@("workshop-discovery"); blocksPhase="Adjudication finalization"; owner="Felton"
                whyBlocking=if ([string]::IsNullOrWhiteSpace($WhyBlocking)) { $null } else { $WhyBlocking.Trim() }
                recommendation=if ([string]::IsNullOrWhiteSpace($Recommendation)) { $null } else { $Recommendation.Trim() }
                alternatives=@($Alternatives | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
                consequences=@("Adjudication finalization cannot proceed until this blocker is resolved and verified.")
                evidenceRequired=($EvidenceRequired -eq "yes"); detailsComplete=$detailsComplete; evidence=$null; status="open"; decision=$null; verified=$false; approvedBy=$null; approvedAt=$null
            }
            $manifest.blockers=@($manifest.blockers)+$newBlocker; $manifest.status="open"; $manifest.finalizedBy=$null; $manifest.finalizedAt=$null
            Save-BlockerManifest $manifest
            foreach ($artifactStage in @("stage6","stage7","stage8")) {
                if ($state.artifacts.PSObject.Properties.Name -contains $artifactStage) { $state.artifacts.PSObject.Properties.Remove($artifactStage) }
            }
            $state.approvals=@($state.approvals | Where-Object { $_.gate -notin @("post-adjudication","post-decision-register","post-implementation","post-validation") })
            $state.currentStage=6; $state.status="awaiting-workshop"; $state.pendingGate="post-adjudication"; $state.lastError=$null; Save-Json $state $stateFile
            Add-RunLog $log "Created workshop blocker $newId - $($newBlocker.title)."
            Complete-CoordinatorTransaction -Action "create" -TransactionBlockerId $newId -Result "created"
            Write-Output "Created $newId - $($newBlocker.title)"
            if ($newBlocker.detailsComplete) { Write-Output "Next: /tt open $newId" } else {
                Write-Output "Now answer these four items for ${newId}:"
                Write-Output "Question: What exact decision must this blocker resolve?"
                Write-Output "Why it blocks: What cannot safely proceed until it is resolved?"
                Write-Output "Recommendation: What is the starting recommendation?"
                Write-Output "Evidence required: yes or no?"
            }
            exit 0
        }
        "define" {
            $item = Get-WorkshopBlocker $manifest $BlockerId
            if ($item.status -eq "resolved" -and $item.verified -eq $true) { throw "$BlockerId is already verified. Use research first if its definition must be reopened." }
            if (-not [string]::IsNullOrWhiteSpace($BlockerQuestion)) { $item.question=$BlockerQuestion.Trim() }
            if (-not [string]::IsNullOrWhiteSpace($WhyBlocking)) { $item.whyBlocking=$WhyBlocking.Trim() }
            if (-not [string]::IsNullOrWhiteSpace($Recommendation)) { $item.recommendation=$Recommendation.Trim() }
            if (@($Alternatives).Count -gt 0) { $item.alternatives=@($Alternatives | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }) }
            $item.evidenceRequired=($EvidenceRequired -eq "yes")
            $detailsComplete=-not [string]::IsNullOrWhiteSpace([string]$item.question) -and -not [string]::IsNullOrWhiteSpace([string]$item.whyBlocking) -and -not [string]::IsNullOrWhiteSpace([string]$item.recommendation)
            $item | Add-Member -NotePropertyName detailsComplete -NotePropertyValue $detailsComplete -Force
            Save-BlockerManifest $manifest; Add-RunLog $log "Updated the workshop definition for blocker $BlockerId."
            Complete-CoordinatorTransaction -Action "define" -TransactionBlockerId $BlockerId -Result $(if ($detailsComplete) { "defined" } else { "definition-incomplete" })
            Write-WorkshopBlocker $item
            if ($detailsComplete) { Write-Output "$BlockerId is fully defined. Discuss or investigate it, then record its decision and evidence." } else { Write-Output "$BlockerId still needs Question, Why it blocks, and Recommendation before it can be verified." }
            exit 0
        }
        "record" {
            if ([string]::IsNullOrWhiteSpace($Decision)) { throw "Decision is required for workshop action 'record'." }
            $item = Get-WorkshopBlocker $manifest $BlockerId
            $item.decision=$Decision
            if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $item.evidence=$Evidence }
            $item.verified=$false; $item.approvedBy=$null; $item.approvedAt=$null
            $item.status=if ($item.evidenceRequired -eq $true -and [string]::IsNullOrWhiteSpace([string]$item.evidence)) { "awaiting-evidence" } else { "proposed" }
            Save-BlockerManifest $manifest; Add-RunLog $log "Recorded a proposed decision for workshop blocker $BlockerId."
            Complete-CoordinatorTransaction -Action "record" -TransactionBlockerId $BlockerId -Result $item.status
            Write-WorkshopBlocker $item
            if ($item.status -eq "awaiting-evidence") { Write-Output "Evidence is still required. Use: /tt record $BlockerId <decision> --evidence <evidence>" } else { Write-Output "When the decision is correct, use: /tt verify $BlockerId" }
            exit 0
        }
        "verify" {
            $item = Get-WorkshopBlocker $manifest $BlockerId
            if ($item.PSObject.Properties.Name -contains "detailsComplete" -and $item.detailsComplete -ne $true) { throw "Complete the definition for $BlockerId before verification." }
            if ([string]::IsNullOrWhiteSpace([string]$item.decision)) { throw "Record a decision for $BlockerId before verification." }
            if ($item.evidenceRequired -eq $true -and [string]::IsNullOrWhiteSpace([string]$item.evidence)) { throw "$BlockerId requires evidence before verification." }
            $item.status="resolved"; $item.verified=$true; $item.approvedBy="Felton"; $item.approvedAt=(Get-Date).ToString("o")
            Save-BlockerManifest $manifest; Add-RunLog $log "Resolved and verified workshop blocker $BlockerId."
            Complete-CoordinatorTransaction -Action "verify" -TransactionBlockerId $BlockerId -Result "resolved-and-verified"
            Write-Output "$BlockerId is resolved and verified."
            Write-WorkshopSummary $manifest
            exit 0
        }
        "finalize" {
            if ($manifest.status -eq "finalized") { throw "Adjudication is already finalized. Resume the saved workflow instead of finalizing it again." }
            $unresolved = @($manifest.blockers | Where-Object { $_.status -ne "resolved" -or $_.verified -ne $true })
            if ($unresolved.Count -gt 0) { throw "Cannot finalize adjudication. Unresolved blockers: $((@($unresolved.id)) -join ', ')" }
            $manifest.status="finalized"; $manifest.finalizedBy="Felton"; $manifest.finalizedAt=(Get-Date).ToString("o"); Save-BlockerManifest $manifest
            $state.approvals = @($state.approvals) + [pscustomobject]@{gate="post-adjudication"; approvedBy="Felton"; timestamp=(Get-Date).ToString("o")}
            $state.currentStage=6; $state.pendingGate=$null; $state.status="ready"; $state.lastError=$null; Save-Json $state $stateFile; Add-RunLog $log "Finalized adjudication workshop and approved post-adjudication."
            Complete-CoordinatorTransaction -Action "finalize" -Gate "post-adjudication" -Result "approved"
            Write-Output "Adjudication is finalized. Starting Stage 6 Decision Register."
        }
    }
}
if ($ApproveGate) {
    if ($ApproveGate -eq "post-adjudication") {
        $manifest = Get-BlockerManifest
        if ($manifest.status -ne "finalized") { throw "Post-adjudication cannot be approved directly. Continue the Triple-Threat blocker workshop, resolve every blocker, then use: /tt finalize adjudication" }
    }
    if ($state.pendingGate -ne $ApproveGate) { throw "Pending gate is $($state.pendingGate), not $ApproveGate." }
    switch ($ApproveGate) {
        "post-architecture" { Assert-Output (Resolve-ArchitectureHandoff $pipe "architecture.md") }
        "post-decision-register" {
            Assert-Output (Join-Path $pipe "decision-register-round-$($state.round).md")
            Assert-Output (Join-Path $pipe "decision-register-receipt-round-$($state.round).md")
        }
        "post-implementation" {
            Assert-Output (Join-Path $pipe "implementation-receipt-round-$($state.round).md")
            Assert-Output (Join-Path $work "IMPLEMENTATION-RUNBOOK.md")
        }
        "post-validation" {
            $finalValidation = Join-Path $pipe "validation-report-round-$($state.round).md"
            Assert-Output $finalValidation
            $finalVerdict = @(Get-Content -Encoding UTF8 -LiteralPath $finalValidation | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
            if ($finalVerdict.Count -ne 1 -or $finalVerdict[0] -notin @("Pass","Pass With Warnings")) { throw "Post-validation approval requires a saved Pass or Pass With Warnings verdict." }
        }
    }
    $state.approvals = @($state.approvals) + [pscustomobject]@{gate=$ApproveGate; approvedBy="Felton"; timestamp=(Get-Date).ToString("o")}
    $state.pendingGate=$null; $state.status="ready"; $state.lastError=$null; Save-Json $state $stateFile; Add-RunLog $log "Approved $ApproveGate."
    Complete-CoordinatorTransaction -Action "approve" -Gate $ApproveGate -Result "approved"
}
if ($RemediateValidation) {
    $validationReport = Join-Path $pipe "validation-report-round-$($state.round).md"
    if ($state.status -eq "failed" -and [int]$state.currentStage -eq 7 -and $state.lastError -like "Remediation receipt does not prove blocking finding*") {
        $receiptPath = Join-Path $pipe "implementation-receipt-round-$($state.round).md"
        $runbookPath = Join-Path $work "IMPLEMENTATION-RUNBOOK.md"
        Assert-Output $validationReport
        Assert-Output $receiptPath
        Assert-Output $runbookPath
        $findingIds = @(
            Get-Content -Encoding UTF8 -LiteralPath $validationReport |
                Select-String -Pattern '^## FAIL Finding\s+([A-Za-z][A-Za-z0-9]*)' |
                ForEach-Object { $_.Matches[0].Groups[1].Value }
        )
        if ($findingIds.Count -eq 0) { throw "Cannot recover remediation because the validation report has no FAIL Finding headings." }
        $receiptText = Get-Content -Raw -Encoding UTF8 -LiteralPath $receiptPath
        foreach ($findingId in $findingIds) {
            if ($receiptText -notmatch ("(?im)^\|\s*{0}(?:\s+[^|]+)?\s*\|.*\|\s*Resolved\s*\|" -f [regex]::Escape($findingId))) {
                throw "Completed remediation receipt still does not prove blocking finding $findingId was resolved."
            }
        }
        foreach ($artifactStage in @("stage8")) {
            if ($state.artifacts.PSObject.Properties.Name -contains $artifactStage) { $state.artifacts.PSObject.Properties.Remove($artifactStage) }
        }
        $state.artifacts | Add-Member -NotePropertyName "stage7" -NotePropertyValue @($receiptPath,$runbookPath) -Force
        $state.currentStage=8; $state.status="awaiting-approval"; $state.pendingGate="post-implementation"; $state.lastError=$null
        Save-Json $state $stateFile
        Add-RunLog $log "Recovered completed Stage 7 remediation after correcting the receipt parser; no specialist was rerun."
        Complete-CoordinatorTransaction -Action "recover-remediation-receipt" -Gate "post-implementation" -Result "awaiting-approval"
        Write-Output "Completed Stage 7 remediation receipt accepted. Codex was not rerun."
        Write-ApprovalInstructions -Gate "post-implementation" -NextStage 8
        exit 0
    }
    if ($state.status -ne "failed" -or [int]$state.currentStage -ne 8) { throw "Validation remediation requires saved state failed at Stage 8." }
    Assert-Output $validationReport
    $verdict = @(Get-Content -Encoding UTF8 -LiteralPath $validationReport | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    if ($verdict.Count -ne 1 -or $verdict[0] -ne "Fail") { throw "Validation remediation requires the saved validation report to end with Fail." }
    foreach ($artifactStage in @("stage7","stage8")) {
        if ($state.artifacts.PSObject.Properties.Name -contains $artifactStage) { $state.artifacts.PSObject.Properties.Remove($artifactStage) }
    }
    $state.currentStage=7; $state.status="ready"; $state.pendingGate=$null; $state.lastError=$null
    Save-Json $state $stateFile; Add-RunLog $log "Opened Stage 7 remediation after a failed Stage 8 validation."
    Complete-CoordinatorTransaction -Action "remediate-validation" -Result "started-stage-7-remediation"
    Write-Output "Validation remediation approved. Rebuilding Stage 7 only; no deployment or activation is authorized."
}
if ($state.status -eq "awaiting-approval") {
    Write-ApprovalInstructions -Gate $state.pendingGate -NextStage ([int]$state.currentStage)
    exit 0
}
if ($state.status -eq "awaiting-workshop") {
    Write-Output "The Triple-Threat workflow is paused for adjudication blocker resolution, not complete."
    Write-Output "Next: /tt work"
    exit 0
}
if ($state.status -eq "failed" -and [int]$state.currentStage -eq 8) {
    Write-Output "Stage 8 validation failed. The implementation must return to Stage 7 before validation can run again."
    Write-Output "Next: /tt Remediate validation for $Project"
    exit 0
}
if (-not [string]::IsNullOrWhiteSpace($TransactionId) -and -not $RemediateValidation -and [int]$state.currentStage -le 8) {
    Complete-CoordinatorTransaction -Action "run" -Result ("started-stage-{0}" -f [int]$state.currentStage)
}
$claude = Join-Path $PSScriptRoot "..\claude-planner-reviewer.ps1"
$codex = Join-Path $PSScriptRoot "..\codex-builder.ps1"
$agy = Join-Path $PSScriptRoot "..\antigravity-reviewer.ps1"
$gates = @{2="post-architecture";5="post-adjudication";6="post-decision-register";7="post-implementation";8="post-validation"}
$stageMessages = @{
    1 = "Reading the project files and creating the project design."
    2 = "Turning the approved design into the project architecture."
    3 = "Checking whether the architecture can be implemented safely."
    4 = "Running the independent architecture review."
    5 = "Reading both reviews and running Claude adjudication."
    6 = "Turning the adjudicated findings into the decision register."
    7 = "Building the approved project files and operator runbook."
    8 = "Checking the completed project against every approved requirement."
}
try {
    for ($n=[Math]::Max($FromStage,[int]$state.currentStage); $n -le $ToStage; $n++) {
        $state.currentStage=$n; $state.status="running"; $state.lastError=$null; Save-Json $state $stateFile; Add-RunLog $log "Starting Stage $n."
        Write-Output $stageMessages[$n]
        switch ($n) {
            1 { & $claude -Stage design -Project $Project -ProjectDir $ProjectDir -ProjectSlug $ProjectSlug -PipelineDir $pipe -Round $state.round -TriliumProjectPath $TriliumProjectPath -OutputArtifact "00-project-design.md" }
            2 { & $claude -Stage architecture -Project $Project -ProjectDir $ProjectDir -ProjectSlug $ProjectSlug -PipelineDir $pipe -Round $state.round -TriliumProjectPath $TriliumProjectPath -ProjectDesignDoc "00-project-design.md" -ArchitectureDoc "architecture.md" -OutputArtifact "architecture-summary.md" }
            3 { & $codex -Mode review -Project $Project -ProjectDir $ProjectDir -ProjectSlug $ProjectSlug -PipelineDir $pipe -Round $state.round -TriliumProjectPath $TriliumProjectPath -ArchitectureDoc "architecture.md" -OutputArtifact "codex-review-round-$($state.round).md" }
            4 { & $agy -Project $Project -ProjectDir $ProjectDir -ProjectSlug $ProjectSlug -PipelineDir $pipe -ArchitectureDoc "architecture.md" -OutputArtifact "ag-review-round-$($state.round).md" }
            5 { & $claude -Stage adjudicate -Project $Project -ProjectDir $ProjectDir -ProjectSlug $ProjectSlug -PipelineDir $pipe -Round $state.round -TriliumProjectPath $TriliumProjectPath -ArchitectureDoc "architecture.md" -CodexReviewDoc "codex-review-round-$($state.round).md" -AntigravityReviewDoc "ag-review-round-$($state.round).md" -BlockerManifestDoc "blockers-round-$($state.round).json" -OutputArtifact "adjudication-receipt-round-$($state.round).md" }
            6 { & $claude -Stage decision-register -Project $Project -ProjectDir $ProjectDir -ProjectSlug $ProjectSlug -PipelineDir $pipe -Round $state.round -TriliumProjectPath $TriliumProjectPath -BlockerManifestDoc "blockers-round-$($state.round).json" -DecisionRegisterDoc "decision-register-round-$($state.round).md" -OutputArtifact "decision-register-receipt-round-$($state.round).md" }
            7 {
                $stage7Args = @{
                    Mode="implement"; Project=$Project; ProjectDir=$ProjectDir; ProjectSlug=$ProjectSlug; PipelineDir=$pipe; Round=$state.round
                    TriliumProjectPath=$TriliumProjectPath; ArchitectureDoc="architecture.md"; DecisionRegisterDoc="decision-register-round-$($state.round).md"
                    OutputArtifact="implementation-receipt-round-$($state.round).md"
                }
                if ($RemediateValidation) { $stage7Args.ValidationReportDoc = "validation-report-round-$($state.round).md" }
                & $codex @stage7Args
            }
            8 { & $claude -Stage validate -Project $Project -ProjectDir $ProjectDir -ProjectSlug $ProjectSlug -PipelineDir $pipe -Round $state.round -TriliumProjectPath $TriliumProjectPath -ArchitectureDoc "architecture.md" -DecisionRegisterDoc "decision-register-round-$($state.round).md" -OutputArtifact "validation-report-round-$($state.round).md" }
        }
        $stageArtifacts = @{
            1 = @("00-project-design.md")
            2 = @("architecture.md", "architecture-summary.md")
            3 = @("codex-review-round-$($state.round).md")
            4 = @("ag-review-round-$($state.round).md")
            5 = @("adjudication-receipt-round-$($state.round).md", "blockers-round-$($state.round).json")
            6 = @("decision-register-round-$($state.round).md", "decision-register-receipt-round-$($state.round).md")
            7 = @("implementation-receipt-round-$($state.round).md", "IMPLEMENTATION-RUNBOOK.md")
            8 = @("validation-report-round-$($state.round).md")
        }
        $recordedArtifacts = @($stageArtifacts[$n] | ForEach-Object { if ($_ -eq "IMPLEMENTATION-RUNBOOK.md") { Join-Path $work $_ } else { Join-Path $pipe $_ } })
        foreach ($artifact in $recordedArtifacts) { Assert-Output $artifact }
        if ($n -eq 8) {
            $validationVerdict = @(Get-Content -Encoding UTF8 -LiteralPath $recordedArtifacts[0] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
            if ($validationVerdict.Count -eq 1 -and $validationVerdict[0] -eq "Pass With Warnings") {
                Initialize-ValidationWarningManifest -Force | Out-Null
                Write-Output "Validation warning follow-up is ready. Use: /tt warnings"
            } elseif ($validationVerdict.Count -eq 1 -and $validationVerdict[0] -eq "Pass" -and (Test-Path -LiteralPath $warningFile -PathType Leaf)) {
                $superseded = "$warningFile.superseded-$(Get-Date -Format yyyyMMdd-HHmmss)"
                Move-Item -LiteralPath $warningFile -Destination $superseded
            }
        }
        $state.artifacts | Add-Member -NotePropertyName ("stage{0}" -f $n) -NotePropertyValue $recordedArtifacts -Force
        Add-RunLog $log "Completed Stage $n."; $state.currentStage=$n+1
        Write-Output "Stage $n is complete."
        if ($gates.ContainsKey($n)) {
            $state.status=if ($n -eq 5) { "awaiting-workshop" } else { "awaiting-approval" }
            $state.pendingGate=$gates[$n]
            Save-Json $state $stateFile
            if ($n -eq 5) {
                Write-Output "The Triple-Threat workflow is paused for adjudication blocker resolution, not complete."
                Write-Output "Next: /tt work"
            } else {
                Write-ApprovalInstructions -Gate $state.pendingGate -NextStage ([int]$state.currentStage)
            }
            exit 0
        }
        Save-Json $state $stateFile
    }
    if ([int]$state.currentStage -gt 8 -and $state.pendingGate -eq $null) {
        $state.status="complete"; Save-Json $state $stateFile; Add-RunLog $log "Pipeline complete."
        Write-Output "Triple-Threat workflow complete. The validated runbook was accepted; nothing was deployed, installed, activated, committed, or pushed."
    } else {
        $state.status="ready"; Save-Json $state $stateFile; Add-RunLog $log "Paused after requested stage range; next stage is $($state.currentStage)."
    }
} catch {
    $state.status="failed"; $state.lastError=$_.Exception.Message; Save-Json $state $stateFile; Add-RunLog $log "FAILED: $($_.Exception.Message)"; throw
}
