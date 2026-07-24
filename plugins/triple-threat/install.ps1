[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$source = $PSScriptRoot
$hermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:LOCALAPPDATA "hermes" }
$destination = Join-Path $hermesHome "plugins\triple-threat"

if (-not (Test-Path -LiteralPath (Join-Path $source "plugin.yaml") -PathType Leaf)) {
    throw "Triple-Threat plugin manifest is missing: $source"
}

New-Item -ItemType Directory -Path $destination -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $source "plugin.yaml") -Destination $destination -Force
Copy-Item -LiteralPath (Join-Path $source "__init__.py") -Destination $destination -Force

$hermesCommand = Join-Path $hermesHome "hermes-agent\venv\Scripts\hermes.exe"
if (-not (Test-Path -LiteralPath $hermesCommand -PathType Leaf)) {
    $resolvedHermes = Get-Command hermes -ErrorAction SilentlyContinue
    if (-not $resolvedHermes) { throw "Hermes command was not found in its native installation or PATH." }
    $hermesCommand = $resolvedHermes.Source
}
& $hermesCommand plugins enable triple-threat
if ($LASTEXITCODE -ne 0) { throw "Hermes could not enable the triple-threat plugin." }

Write-Output "Triple-Threat Hermes plugin installed and enabled."
Write-Output "Restart Hermes once, then use: /tt status"
