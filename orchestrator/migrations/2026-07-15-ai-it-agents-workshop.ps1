[CmdletBinding()]
param(
    [string]$PipelineDir = (Join-Path $env:LOCALAPPDATA "hermes\pipelines\ai-it-agents")
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\..\pipeline-common.ps1")

$manifestPath = Join-Path $PipelineDir "blockers-round-1.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "AI IT Agents blocker manifest not found: $manifestPath"
}

function Repair-Mojibake([AllowNull()][string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $windows1252 = [Text.Encoding]::GetEncoding(1252)
    $utf8 = [Text.Encoding]::UTF8
    $markers = @([char]0x00C3, [char]0x00C2, [char]0x00E2)
    for ($round = 0; $round -lt 6; $round++) {
        if (@($markers | Where-Object { $Text.Contains($_) }).Count -eq 0) { break }
        $candidate = $utf8.GetString($windows1252.GetBytes($Text))
        if ($candidate -eq $Text -or $candidate.Contains([char]0xFFFD)) { break }
        $Text = $candidate
    }
    return $Text
}

$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
foreach ($blocker in @($manifest.blockers)) {
    foreach ($property in @(
        "id", "title", "question", "type", "blocksPhase", "owner", "whyBlocking",
        "recommendation", "decision", "evidence", "approvedBy"
    )) {
        if ($blocker.PSObject.Properties.Name -contains $property) {
            $blocker.$property = Repair-Mojibake ([string]$blocker.$property)
        }
    }
    foreach ($property in @("sourceFindingIds", "alternatives", "consequences")) {
        if ($blocker.PSObject.Properties.Name -contains $property) {
            $blocker.$property = @($blocker.$property | ForEach-Object { Repair-Mojibake ([string]$_) })
        }
    }

    $embeddedCommand = " /tt record $($blocker.id) "
    if (-not [string]::IsNullOrWhiteSpace([string]$blocker.evidence)) {
        $marker = $blocker.evidence.IndexOf($embeddedCommand, [StringComparison]::OrdinalIgnoreCase)
        if ($marker -ge 0) { $blocker.evidence = $blocker.evidence.Substring(0, $marker).Trim() }
    }
}

if (@($manifest.blockers | Where-Object { $_.id -eq "B7" }).Count -eq 0) {
    $b7 = [pscustomobject]@{
        id = "B7"
        title = "Correlated-outage clustering"
        question = "How will alerts for services that fail together because of one shared upstream dependency be clustered into one incident instead of creating separate tickets?"
        type = "technical-design"
        sourceFindingIds = @("B2-closeout")
        blocksPhase = "Adjudication finalization"
        owner = "Felton"
        whyBlocking = "The service-specific deduplication key can create multiple incidents and multiple AI-triage calls for one shared outage."
        recommendation = "Before AI triage, use a non-AI n8n step to correlate near-simultaneous failures through Hexmap dependency relationships and collapse shared-upstream failures into one candidate incident."
        alternatives = @(
            "Add a read-only topology endpoint to hexmap-api",
            "Export a periodically refreshed dependency map for n8n",
            "Use a limited static dependency map until the API exists",
            "Keep per-service incidents and link them after creation"
        )
        consequences = @(
            "The correlation window and topology source must be explicit",
            "Stage 8 must test simultaneous failures sharing an upstream dependency"
        )
        evidenceRequired = $true
        evidence = "Nextcloud and Syncthing both dropped within the same minute on 2026-07-09 at approximately 10:48 and recovered together. The remaining evidence requirement is confirmation of a queryable Hexmap topology source for n8n."
        status = "open"
        decision = $null
        verified = $false
        approvedBy = $null
        approvedAt = $null
    }
    $manifest.blockers = @($manifest.blockers) + $b7
}

$backupPath = "$manifestPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -LiteralPath $manifestPath -Destination $backupPath
Save-Json $manifest $manifestPath

$remaining = @($manifest.blockers | Where-Object { $_.status -ne "resolved" -or $_.verified -ne $true })
Write-Output "Workshop state repaired and backed up to: $backupPath"
Write-Output "Registered blockers: $(@($manifest.blockers).Count)"
Write-Output "Remaining blockers: $((@($remaining.id)) -join ', ')"
