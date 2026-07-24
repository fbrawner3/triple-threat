[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$runner = Join-Path $repo "hermes\skills\triple-threat-orchestrator\run.ps1"
$id = [Guid]::NewGuid().ToString("N").Substring(0,10)
$project = "Hermes Isolated Test"
$projectDir = "hermes-test-$id"
$projectPath = Join-Path $repo $projectDir
$slug = "hermes-test-$id"
$originalLocalAppData = $env:LOCALAPPDATA
$isolatedLocalAppData = Join-Path $projectPath "localappdata"
$env:LOCALAPPDATA = $isolatedLocalAppData
$pipeline = Join-Path $isolatedLocalAppData "hermes\pipelines\$slug"
$env:TRIPLE_THREAT_CODEX_COMMAND = Join-Path $PSScriptRoot "fake-codex.ps1"
$env:TRIPLE_THREAT_CLAUDE_COMMAND = Join-Path $PSScriptRoot "fake-claude.ps1"
$env:TRIPLE_THREAT_AGY_COMMAND = Join-Path $PSScriptRoot "fake-agy.ps1"

function Invoke-Run([hashtable]$Extra) {
    $arguments=@{Project=$project;ProjectSlug=$slug;ProjectDir=$projectDir;TriliumProjectPath="Planner/Projects/$project";FromStage=1;ToStage=8}
    foreach($key in $Extra.Keys){$arguments[$key]=$Extra[$key]}
    & $runner @arguments
}
function Get-State { Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $pipeline "state.json") | ConvertFrom-Json }
function Save-State($state) { [IO.File]::WriteAllText((Join-Path $pipeline "state.json"),(($state|ConvertTo-Json -Depth 12)+"`n"),[Text.UTF8Encoding]::new($false)) }
function Tx { [Guid]::NewGuid().ToString("D") }
function Assert-Eq($actual,$expected,[string]$message){if($actual -ne $expected){throw "$message Expected '$expected', got '$actual'."}}

try {
    [void][IO.Directory]::CreateDirectory($projectPath)
    [IO.File]::WriteAllText((Join-Path $projectPath "input.md"),"# Test",[Text.UTF8Encoding]::new($false))
    $validation=@(Invoke-Run @{ValidateOnly=$true}) -join "`n"
    if($validation -notmatch "No agent was invoked"){throw "ValidateOnly guarantee missing."}
    if(Test-Path $pipeline){throw "ValidateOnly created runtime state."}

    Invoke-Run @{ToStage=1;TransactionId=(Tx)} | Out-Null
    Assert-Eq (Get-State).currentStage 2 "Partial stage range failed."
    Invoke-Run @{TransactionId=(Tx)} | Out-Null
    Assert-Eq (Get-State).pendingGate "post-architecture" "Architecture gate failed."
    Remove-Item -LiteralPath (Join-Path $pipeline "architecture.md") -Force
    $before=(Get-FileHash (Join-Path $pipeline "state.json") -Algorithm SHA256).Hash
    $preflight=@(Invoke-Run @{PreflightOnly=$true}) -join "`n"
    if($preflight -notmatch "architecture-summary.md"){throw "Legacy architecture fallback failed."}
    Assert-Eq (Get-FileHash (Join-Path $pipeline "state.json") -Algorithm SHA256).Hash $before "Preflight changed state."

    Invoke-Run @{ApproveGate="post-architecture";TransactionId=(Tx)} | Out-Null
    Assert-Eq (Get-State).status "awaiting-workshop" "Workshop gate failed."
    Invoke-Run @{WorkshopAction="record";BlockerId="B1";Decision="Test decision";Evidence="Test evidence";TransactionId=(Tx)} | Out-Null
    Invoke-Run @{WorkshopAction="verify";BlockerId="B1";TransactionId=(Tx)} | Out-Null
    Invoke-Run @{WorkshopAction="create";BlockerTitle="New blocker";TransactionId=(Tx)} | Out-Null
    Invoke-Run @{WorkshopAction="define";BlockerId="B2";BlockerQuestion="Question";WhyBlocking="Why";Recommendation="Recommendation";EvidenceRequired="no";TransactionId=(Tx)} | Out-Null
    Invoke-Run @{WorkshopAction="record";BlockerId="B2";Decision="Decision";TransactionId=(Tx)} | Out-Null
    Invoke-Run @{WorkshopAction="verify";BlockerId="B2";TransactionId=(Tx)} | Out-Null
    Invoke-Run @{WorkshopAction="finalize";TransactionId=(Tx)} | Out-Null
    Assert-Eq (Get-State).pendingGate "post-decision-register" "Decision gate failed."
    Invoke-Run @{ApproveGate="post-decision-register";TransactionId=(Tx)} | Out-Null
    Assert-Eq (Get-State).pendingGate "post-implementation" "Implementation gate failed."

    Invoke-Run @{WorkshopAction="create";BlockerTitle="Late blocker";TransactionId=(Tx)} | Out-Null
    $state=Get-State
    Assert-Eq $state.currentStage 6 "Late blocker did not invalidate downstream stages."
    Assert-Eq $state.status "awaiting-workshop" "Late blocker did not reopen the workshop."
    if($state.artifacts.PSObject.Properties.Name -contains "stage6" -or $state.artifacts.PSObject.Properties.Name -contains "stage7"){throw "Late blocker retained invalid downstream artifacts."}
    if(@($state.approvals | Where-Object {$_.gate -in @("post-decision-register","post-implementation","post-validation")}).Count){throw "Late blocker retained invalid downstream approvals."}
    Invoke-Run @{WorkshopAction="define";BlockerId="B3";BlockerQuestion="Question";WhyBlocking="Why";Recommendation="Recommendation";EvidenceRequired="no";TransactionId=(Tx)} | Out-Null
    Invoke-Run @{WorkshopAction="record";BlockerId="B3";Decision="Decision";TransactionId=(Tx)} | Out-Null
    Invoke-Run @{WorkshopAction="verify";BlockerId="B3";TransactionId=(Tx)} | Out-Null
    Invoke-Run @{WorkshopAction="finalize";TransactionId=(Tx)} | Out-Null
    Assert-Eq (Get-State).pendingGate "post-decision-register" "Late-blocker decision register did not rerun."
    Invoke-Run @{ApproveGate="post-decision-register";TransactionId=(Tx)} | Out-Null
    Assert-Eq (Get-State).pendingGate "post-implementation" "Late-blocker implementation did not rerun."

    $env:TRIPLE_THREAT_FAKE_VALIDATION_FAIL="1"
    $failed=$false
    try { Invoke-Run @{ApproveGate="post-implementation";TransactionId=(Tx)} | Out-Null } catch { $failed=$true }
    if(-not $failed){throw "Fail verdict did not fail Stage 8."}
    Assert-Eq (Get-State).status "failed" "Stage 8 failure state missing."
    Remove-Item Env:TRIPLE_THREAT_FAKE_VALIDATION_FAIL

    Invoke-Run @{RemediateValidation=$true;TransactionId=(Tx)} | Out-Null
    Assert-Eq (Get-State).pendingGate "post-implementation" "Stage 7 remediation did not stop at its gate."
    $state=Get-State
    $state.currentStage=7; $state.status="failed"; $state.pendingGate=$null
    $state.lastError="Remediation receipt does not prove blocking finding F1 was resolved."
    Save-State $state
    $receiptPath=Join-Path $pipeline "implementation-receipt-round-1.md"
    $receiptHash=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash
    Invoke-Run @{RemediateValidation=$true;TransactionId=(Tx)} | Out-Null
    Assert-Eq (Get-State).pendingGate "post-implementation" "Completed-receipt recovery did not restore the gate."
    Assert-Eq (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash $receiptHash "Completed-receipt recovery reran Codex."
    Invoke-Run @{ApproveGate="post-implementation";TransactionId=(Tx)} | Out-Null
    Assert-Eq (Get-State).pendingGate "post-validation" "Passing validation did not stop at final handoff."
    $validationPath=Join-Path $pipeline "validation-report-round-1.md"
    [IO.File]::WriteAllText($validationPath,"# Validation Report`n`nFail`n",[Text.UTF8Encoding]::new($false))
    $blocked=$false
    try { Invoke-Run @{ApproveGate="post-validation";TransactionId=(Tx)} | Out-Null } catch { $blocked=$true }
    if(-not $blocked){throw "Post-validation accepted a failed verdict."}
    [IO.File]::WriteAllText($validationPath,"# Validation Report`n`nPass`n",[Text.UTF8Encoding]::new($false))
    $completion=@(Invoke-Run @{ApproveGate="post-validation";TransactionId=(Tx)}) -join "`n"
    if($completion -notmatch "workflow complete"){throw "Final approval returned no completion feedback."}
    $state=Get-State
    Assert-Eq $state.status "complete" "Final handoff failed."
    foreach($stage in 1..8){if($state.artifacts.PSObject.Properties.Name -notcontains "stage$stage"){throw "Missing Stage $stage artifacts."}}
    $warningReport=@"
# Validation Report

## Warnings Summary

| ID | Description | Status |
| --- | --- | --- |
| W3 | Configure the exact execution-error workflow | Open |
| W4 | Already corrected warning | **Resolved** |
| W6 | Make evaluate an activation prerequisite | New/Open |

Pass With Warnings
"@
    [IO.File]::WriteAllText($validationPath,$warningReport,[Text.UTF8Encoding]::new($false))
    Invoke-Run @{ValidationWarningAction="initialize";TransactionId=(Tx)} | Out-Null
    $warningPath=Join-Path $pipeline "validation-warnings-round-1.json"
    if(-not (Test-Path -LiteralPath $warningPath)){throw "Warning manifest was not created."}
    $warnings=Get-Content -Raw -Encoding UTF8 $warningPath | ConvertFrom-Json
    Assert-Eq @($warnings.warnings).Count 2 "Resolved validation rows were not excluded."
    $warnings.warnings += [pscustomobject]@{id="W4";description="Already corrected warning";sourceStatus="Resolved";status="open";decision=$null;evidence=$null;evidenceRequired=$true;verified=$false;approvedBy=$null;approvedAt=$null}
    [IO.File]::WriteAllText($warningPath,(($warnings | ConvertTo-Json -Depth 20) + "`n"),[Text.UTF8Encoding]::new($false))
    Invoke-Run @{ValidationWarningAction="reconcile";TransactionId=(Tx)} | Out-Null
    $warnings=Get-Content -Raw -Encoding UTF8 $warningPath | ConvertFrom-Json
    Assert-Eq @($warnings.warnings).Count 2 "Warning reconciliation did not remove a legacy resolved row."
    if (@($warnings.warnings | Where-Object {$_.id -eq "W4"}).Count) { throw "Warning reconciliation retained resolved W4." }
    Assert-Eq @($warnings.sourceResolvedWarnings).Count 1 "Warning reconciliation did not preserve the source-resolved rows."
    Assert-Eq $warnings.sourceResolvedWarnings[0].id "W4" "Warning reconciliation preserved the wrong source-resolved row."
    $beforeWarningState=Get-State
    Invoke-Run @{ValidationWarningAction="record";WarningId="W3";WarningDecision="Create the n8n error workflow.";WarningEvidence="Workflow export reviewed.";TransactionId=(Tx)} | Out-Null
    Invoke-Run @{ValidationWarningAction="verify";WarningId="W3";TransactionId=(Tx)} | Out-Null
    Invoke-Run @{ValidationWarningAction="record";WarningId="W6";WarningDecision="Add evaluate to prerequisites.";WarningEvidence="Runbook prerequisite reviewed.";TransactionId=(Tx)} | Out-Null
    Invoke-Run @{ValidationWarningAction="verify";WarningId="W6";TransactionId=(Tx)} | Out-Null
    $warnings=Get-Content -Raw -Encoding UTF8 $warningPath | ConvertFrom-Json
    Assert-Eq $warnings.status "resolved" "Warning follow-up did not resolve."
    $afterWarningState=Get-State
    Assert-Eq $afterWarningState.currentStage $beforeWarningState.currentStage "Warning work changed the completed stage."
    Assert-Eq $afterWarningState.status "complete" "Warning work reopened the completed workflow."
    Write-Output "HERMES ISOLATED E2E PASS: validation, stages, gates, workshop creation/definition, warning follow-up, receipts, legacy architecture fallback, Stage 8 failure, Stage 7 remediation, and final handoff."
} finally {
    $env:LOCALAPPDATA=$originalLocalAppData
    foreach($name in @("TRIPLE_THREAT_CODEX_COMMAND","TRIPLE_THREAT_CLAUDE_COMMAND","TRIPLE_THREAT_AGY_COMMAND","TRIPLE_THREAT_FAKE_VALIDATION_FAIL")){Remove-Item "Env:$name" -ErrorAction SilentlyContinue}
    if(Test-Path $projectPath){Remove-Item -LiteralPath $projectPath -Recurse -Force}
}
