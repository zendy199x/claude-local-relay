param(
  [Parameter(Position = 0)]
  [string]$ModelId
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

if (-not (Test-Path ".env")) {
  Copy-Item ".env.example" ".env"
}

if ([string]::IsNullOrWhiteSpace($ModelId)) {
  try {
    $models = Invoke-RestMethod -Uri "http://127.0.0.1:1234/v1/models"
  } catch {
    throw "Cannot reach LM Studio on 127.0.0.1:1234. Start LM Studio server first."
  }

  $ids = @($models.data | ForEach-Object { $_.id } | Where-Object { $_ })
  if ($ids.Count -eq 0) {
    throw "No models found. Load a model in LM Studio first."
  }
  if ($ids.Count -gt 1) {
    Write-Host "Multiple models found. Specify one model id explicitly:"
    $ids | ForEach-Object { Write-Host "  $_" }
    exit 1
  }
  $ModelId = $ids[0]
}

$lines = Get-Content ".env"
$updated = $false
$out = foreach ($line in $lines) {
  if ($line -match '^LOCAL_MODEL=') {
    $updated = $true
    "LOCAL_MODEL=$ModelId"
  } else {
    $line
  }
}
if (-not $updated) {
  $out += "LOCAL_MODEL=$ModelId"
}
$out | Set-Content ".env"

Write-Host "Updated .env -> LOCAL_MODEL=$ModelId"
