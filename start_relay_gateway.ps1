param()

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

if (-not (Test-Path ".env")) {
  Copy-Item ".env.example" ".env"
  Write-Host "Created .env from .env.example"
}

if (-not (Test-Path ".venv")) {
  if (Get-Command py -ErrorAction SilentlyContinue) {
    py -3 -m venv .venv
  } elseif (Get-Command python -ErrorAction SilentlyContinue) {
    python -m venv .venv
  } else {
    throw "Python was not found. Run .\setup_windows.ps1 first."
  }
}

$venvPython = Join-Path $ScriptDir ".venv\Scripts\python.exe"
& $venvPython -m pip install --upgrade pip | Out-Null
& $venvPython -m pip install -r requirements.txt | Out-Null

$envMap = @{}
Get-Content ".env" | ForEach-Object {
  if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
  $parts = $_ -split '=', 2
  $k = $parts[0].Trim()
  $v = $parts[1]
  if ($k) {
    $envMap[$k] = $v
    [Environment]::SetEnvironmentVariable($k, $v, "Process")
  }
}

$listenHost = if ($envMap.ContainsKey("LISTEN_HOST")) { $envMap["LISTEN_HOST"] } else { "127.0.0.1" }
$listenPort = if ($envMap.ContainsKey("LISTEN_PORT")) { $envMap["LISTEN_PORT"] } else { "4000" }

if ((-not $envMap.ContainsKey("LOCAL_MODEL") -or [string]::IsNullOrWhiteSpace($envMap["LOCAL_MODEL"])) -and -not [string]::IsNullOrWhiteSpace($env:RELAY_RUNTIME_LOCAL_MODEL)) {
  $envMap["LOCAL_MODEL"] = $env:RELAY_RUNTIME_LOCAL_MODEL
  [Environment]::SetEnvironmentVariable("LOCAL_MODEL", $env:RELAY_RUNTIME_LOCAL_MODEL, "Process")
  Write-Host "Using runtime-selected local model override: $($env:RELAY_RUNTIME_LOCAL_MODEL)"
}

Write-Host "Starting Claude Local Relay gateway on $listenHost:$listenPort"
& $venvPython -m uvicorn claude_local_relay_gateway:app --host $listenHost --port $listenPort
