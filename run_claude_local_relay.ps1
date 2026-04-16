param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ClaudeArgs
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

function Test-Command {
  param([string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Read-EnvFile {
  param([string]$Path)
  $map = @{}
  Get-Content $Path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
    $parts = $_ -split '=', 2
    $key = $parts[0].Trim()
    $value = $parts[1]
    if ($key) {
      $map[$key] = $value
    }
  }
  return $map
}

function Ensure-Lms {
  if (Test-Command "lms") {
    return
  }
  $candidate = Join-Path $HOME ".lmstudio\bin\lms.exe"
  if (Test-Path $candidate) {
    $env:Path = "$(Split-Path $candidate);$env:Path"
    return
  }
  throw "LM Studio CLI (lms) was not found. Run .\setup_windows.ps1 -InstallLMStudio first."
}

function Ensure-LmServer {
  $daemonJson = & lms daemon status --json --quiet 2>$null
  $daemon = $null
  try { $daemon = $daemonJson | ConvertFrom-Json } catch {}
  if (-not $daemon -or $daemon.status -ne "running") {
    & lms daemon up | Out-Null
  }

  $serverJson = & lms server status --json --quiet 2>$null
  $server = $null
  try { $server = $serverJson | ConvertFrom-Json } catch {}
  if (-not $server -or $server.running -ne $true) {
    & lms server start | Out-Null
  }
}

function Detect-RamGb {
  try {
    $bytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    if ($bytes -gt 0) {
      return [Math]::Floor($bytes / 1GB)
    }
  } catch {}
  return 0
}

function Select-ModelKey {
  param(
    [hashtable]$EnvMap
  )
  $stable = if ($EnvMap["STABLE_MODEL_KEY"]) { $EnvMap["STABLE_MODEL_KEY"] } else { "google/gemma-3n-e4b" }
  $profile = if ($EnvMap["RELAY_MODEL_PROFILE"]) { $EnvMap["RELAY_MODEL_PROFILE"] } else { "auto" }
  $ramGb = Detect-RamGb

  if ($profile -eq "stable" -or $ramGb -lt 48) {
    return $stable
  }
  return "google/gemma-4-31b"
}

function Ensure-Model {
  param(
    [hashtable]$EnvMap
  )
  $stableKey = if ($EnvMap["STABLE_MODEL_KEY"]) { $EnvMap["STABLE_MODEL_KEY"] } else { "google/gemma-3n-e4b" }
  $stableId = if ($EnvMap["STABLE_MODEL_IDENTIFIER"]) { $EnvMap["STABLE_MODEL_IDENTIFIER"] } else { "gemma-3n-e4b-it-local" }
  $ctx = if ($EnvMap["LOCAL_CONTEXT_LENGTH"]) { $EnvMap["LOCAL_CONTEXT_LENGTH"] } else { "32768" }

  $targetId = $EnvMap["LOCAL_MODEL"]
  $targetKey = $null
  if ([string]::IsNullOrWhiteSpace($targetId)) {
    $targetKey = Select-ModelKey -EnvMap $EnvMap
    if ($targetKey -eq $stableKey) {
      $targetId = $stableId
    } else {
      $targetId = $targetKey
    }
  }

  if (-not $targetKey) {
    if ($targetId -eq $stableId) {
      $targetKey = $stableKey
    } else {
      $targetKey = $targetId
    }
  }

  & lms load $targetKey --identifier $targetId --context-length $ctx -y | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Preferred model failed, switching to stable fallback..." -ForegroundColor Yellow
    & lms load $stableKey --identifier $stableId --context-length $ctx -y | Out-Null
    & "$ScriptDir\set_relay_model.ps1" $stableId | Out-Null
    [Environment]::SetEnvironmentVariable("RELAY_RUNTIME_LOCAL_MODEL", $stableId, "Process")
  } else {
    [Environment]::SetEnvironmentVariable("RELAY_RUNTIME_LOCAL_MODEL", $targetId, "Process")
  }
}

function Ensure-Gateway {
  param(
    [string]$HealthUrl
  )
  try {
    $null = Invoke-RestMethod -Uri $HealthUrl -TimeoutSec 2
    return
  } catch {}

  $logPath = "$env:TEMP\claude-local-relay-gateway.log"
  Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptDir\start_relay_gateway.ps1`"" -WindowStyle Hidden -RedirectStandardOutput $logPath -RedirectStandardError $logPath | Out-Null

  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
      $null = Invoke-RestMethod -Uri $HealthUrl -TimeoutSec 2
      return
    } catch {}
  }

  throw "Gateway failed to start at $HealthUrl"
}

if (-not (Test-Command "claude")) {
  throw "Claude CLI was not found. Run .\setup_windows.ps1 -InstallClaude first."
}

if (-not (Test-Path ".env")) {
  Copy-Item ".env.example" ".env"
  Write-Host "Created .env from .env.example"
}

$envMap = Read-EnvFile -Path ".env"
$envMap.Keys | ForEach-Object {
  [Environment]::SetEnvironmentVariable($_, $envMap[$_], "Process")
}

Ensure-Lms
Ensure-LmServer
Ensure-Model -EnvMap $envMap

$listenHost = if ($envMap["LISTEN_HOST"]) { $envMap["LISTEN_HOST"] } else { "127.0.0.1" }
$listenPort = if ($envMap["LISTEN_PORT"]) { $envMap["LISTEN_PORT"] } else { "4000" }
$baseUrl = "http://$listenHost`:$listenPort"
$healthUrl = "$baseUrl/healthz"

Ensure-Gateway -HealthUrl $healthUrl

$env:ANTHROPIC_BASE_URL = $baseUrl
$env:ANTHROPIC_API_KEY = if ($envMap["PROXY_CLIENT_TOKEN"]) { $envMap["PROXY_CLIENT_TOKEN"] } else { "claude-local-relay" }
Remove-Item Env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue

$cloudEnabled = ($envMap["ENABLE_CLOUD_ANTHROPIC"] -eq "true" -and -not [string]::IsNullOrWhiteSpace($envMap["CLOUD_ANTHROPIC_API_KEY"]))
$hasSystemPromptArg = $ClaudeArgs -contains "--append-system-prompt" -or $ClaudeArgs -contains "--system-prompt"
$hasBareArg = $ClaudeArgs -contains "--bare"
$hasExcludeArg = $ClaudeArgs -contains "--exclude-dynamic-system-prompt-sections"

$finalArgs = @($ClaudeArgs)
if (-not $cloudEnabled -and -not $hasSystemPromptArg) {
  $compatPrompt = if ($envMap["RELAY_COMPAT_SYSTEM_PROMPT"]) { $envMap["RELAY_COMPAT_SYSTEM_PROMPT"] } else { "Reply directly in the user's language. Do not output protocol JSON/YAML/XML. Use tools only when needed." }
  $finalArgs += @("--append-system-prompt", $compatPrompt)
}
if (-not $cloudEnabled -and $envMap["RELAY_FAST_BARE_MODE"] -eq "true" -and -not $hasBareArg) {
  $finalArgs += "--bare"
}
if (-not $cloudEnabled -and $envMap["RELAY_EXCLUDE_DYNAMIC_PROMPT"] -eq "true" -and -not $hasExcludeArg) {
  $finalArgs += "--exclude-dynamic-system-prompt-sections"
}

Write-Host "Claude is now pointed to Claude Local Relay at $baseUrl"
& claude @finalArgs
