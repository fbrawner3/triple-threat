$allArguments = @($args)
if ($allArguments -contains "--version") { Write-Output "fake claude 1.0"; exit 0 }
$promptIndex = [Array]::IndexOf($allArguments, "-p")
if ($promptIndex -lt 0) { throw "Fake Claude did not receive a prompt." }
$prompt = $allArguments[$promptIndex + 1]
function Write-FakeFile([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path.TrimEnd('.'), $Text, [Text.UTF8Encoding]::new($false)) }
$paths = @([regex]::Matches($prompt, '[A-Z]:\\[^\s]+?\.(?:md|json)') | ForEach-Object { $_.Value.TrimEnd('.') } | Sort-Object -Unique)
foreach ($path in $paths) {
    if ($path.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) {
        if ($prompt -match 'Create strict JSON') {
            $manifest = [ordered]@{ version=1; project="Hermes Isolated Test"; round=1; status="open"; finalizedBy=$null; finalizedAt=$null; blockers=@([ordered]@{ id="B1"; title="Test blocker"; question="What is the decision?"; type="test"; sourceFindingIds=@("T1"); blocksPhase="Stage 6"; owner="Felton"; whyBlocking="Test"; recommendation="Resolve"; alternatives=@("Defer"); consequences=@("Blocked"); evidenceRequired=$true; detailsComplete=$true; evidence=$null; status="open"; decision=$null; verified=$false; approvedBy=$null; approvedAt=$null }) }
            Write-FakeFile $path (($manifest | ConvertTo-Json -Depth 10) + "`n")
        }
        continue
    } elseif ($prompt -match 'Read-only validate' -and $path -match 'validation-report') {
        $verdict = if ($env:TRIPLE_THREAT_FAKE_VALIDATION_FAIL -eq "1") { "Fail" } else { "Pass" }
        $body = if ($verdict -eq "Fail") { "# Validation Report`n`n## FAIL Finding F1 - Test routing defect`n`n## Required fixes before re-validation`n`n1. Correct the test routing defect.`n`nFail" } else { "# Validation Report`n`nPass" }
        Write-FakeFile $path $body
    } elseif ($path -match 'architecture\.md$') { Write-FakeFile $path "# Architecture" }
    elseif ($path -match 'decision-register') { Write-FakeFile $path "# Decision Register" }
    else { Write-FakeFile $path "# Fake Claude Artifact" }
}
[Console]::Error.WriteLine("fake claude harmless warning")
@{ result="Fake Claude completed."; permission_denials=@() } | ConvertTo-Json -Compress
