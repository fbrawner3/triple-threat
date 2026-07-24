$allArguments = @($args)
if ($allArguments -contains "--help") { Write-Output "fake codex help"; exit 0 }
$disableIndex = [Array]::IndexOf($allArguments, "--disable")
if ($disableIndex -lt 0 -or $allArguments[$disableIndex + 1] -ne "plugins") { throw "Codex plugins were not disabled." }
foreach ($required in @("exec", "--sandbox", "workspace-write", "--json", "-o")) {
    if ($allArguments -notcontains $required) { throw "Codex launch omitted: $required" }
}
$prompt = (($input | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
$outputIndex = [Array]::IndexOf($allArguments, "-o")
if ($outputIndex -ge 0) { [IO.File]::WriteAllText($allArguments[$outputIndex + 1], "Fake Codex completed.", [Text.UTF8Encoding]::new($false)) }
$paths = [regex]::Matches($prompt, '(?i)[A-Z]:\\[^\s]+?\.md') | ForEach-Object { $_.Value.Trim() } | Where-Object { $_ -match '(?i)\\hermes\\pipelines\\' }
foreach ($path in @($paths | Sort-Object -Unique)) {
    if ($path -match 'validation-report') { continue }
    $content = if ($path -match 'implementation-receipt') { "# Implementation Receipt`n`n## Blocking Findings Resolved`n`n| Finding | Files changed | Verification | Status |`n|---|---|---|---|`n| F1 - Test routing defect | test.json | Direct routing check | Resolved |" } else { "# Fake Codex Artifact" }
    [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
}
if ($prompt -match '(?i)([A-Z]:\\[^\s]+?IMPLEMENTATION-RUNBOOK\.md)') {
    [IO.File]::WriteAllText($Matches[1], "# Implementation Runbook`n`nManual go-live approval is required.", [Text.UTF8Encoding]::new($false))
}
[Console]::Error.WriteLine("fake codex harmless warning")
Write-Output '{"type":"result","result":"success"}'
