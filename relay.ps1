param(
  [Parameter(Position = 0)]
  [string]$Command = "run",
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Arguments
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Show-Usage {
  @"
Claude Local Relay CLI (PowerShell)

Usage:
  .\relay.ps1 bootstrap [claude args...]
  .\relay.ps1 run [claude args...]
  .\relay.ps1 setup
  .\relay.ps1 gateway
  .\relay.ps1 set-model <model-id>
  .\relay.ps1 health
  .\relay.ps1 doctor
  .\relay.ps1 help
"@
}

switch ($Command) {
  "bootstrap" {
    & "$ScriptDir\setup_windows.ps1" -InstallLMStudio -InstallClaude
    & "$ScriptDir\run_claude_local_relay.ps1" @Arguments
    break
  }
  "run" {
    & "$ScriptDir\run_claude_local_relay.ps1" @Arguments
    break
  }
  "setup" {
    & "$ScriptDir\setup_windows.ps1" @Arguments
    break
  }
  "gateway" {
    & "$ScriptDir\start_relay_gateway.ps1" @Arguments
    break
  }
  "set-model" {
    & "$ScriptDir\set_relay_model.ps1" @Arguments
    break
  }
  "health" {
    Invoke-RestMethod -Uri "http://127.0.0.1:4000/healthz" | ConvertTo-Json -Depth 8
    break
  }
  "doctor" {
    $required = @(
      "relay.ps1",
      "run_claude_local_relay.ps1",
      "start_relay_gateway.ps1",
      "setup_windows.ps1",
      "claude_local_relay_gateway.py"
    )
    foreach ($file in $required) {
      if (-not (Test-Path (Join-Path $ScriptDir $file))) {
        throw "Missing required file: $file"
      }
    }
    if (Get-Command py -ErrorAction SilentlyContinue) {
      py -3 -m py_compile (Join-Path $ScriptDir "claude_local_relay_gateway.py")
    } elseif (Get-Command python -ErrorAction SilentlyContinue) {
      python -m py_compile (Join-Path $ScriptDir "claude_local_relay_gateway.py")
    }
    Write-Host "Doctor checks passed."
    break
  }
  "help" {
    Show-Usage
    break
  }
  default {
    Write-Host "Unknown command: $Command" -ForegroundColor Red
    Show-Usage
    exit 1
  }
}
