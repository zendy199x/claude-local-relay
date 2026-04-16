param(
  [switch]$InstallLMStudio,
  [switch]$InstallClaude
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

function Test-Command {
  param([string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-WithWinget {
  param(
    [string]$Id
  )
  if (-not (Test-Command "winget")) {
    return
  }
  Write-Host "Installing $Id with winget..."
  winget install --id $Id --silent --accept-package-agreements --accept-source-agreements | Out-Null
}

if (-not (Test-Command "python") -and -not (Test-Command "py")) {
  Install-WithWinget -Id "Python.Python.3.11"
}

if ($InstallClaude -and -not (Test-Command "npm")) {
  Install-WithWinget -Id "OpenJS.NodeJS.LTS"
}

if (-not (Test-Command "jq")) {
  Install-WithWinget -Id "jqlang.jq"
}

if ($InstallLMStudio) {
  # Package IDs can differ between regions; try common candidates.
  $lmIds = @("LMStudio.LMStudio", "ElementLabs.LMStudio")
  foreach ($lmId in $lmIds) {
    try {
      Install-WithWinget -Id $lmId
      break
    } catch {
      continue
    }
  }
}

$pythonExe = $null
if (Test-Command "py") {
  $pythonExe = "py -3"
} elseif (Test-Command "python") {
  $pythonExe = "python"
} else {
  throw "Python was not found. Install Python 3.11 and rerun setup."
}

if (-not (Test-Path ".venv")) {
  Invoke-Expression "$pythonExe -m venv .venv"
}

$venvPython = Join-Path $ScriptDir ".venv\Scripts\python.exe"
& $venvPython -m pip install --upgrade pip | Out-Null
& $venvPython -m pip install -r requirements.txt | Out-Null

if (-not (Test-Path ".env")) {
  Copy-Item ".env.example" ".env"
  Write-Host "Created .env from .env.example"
}

if ($InstallClaude -and -not (Test-Command "claude")) {
  if (-not (Test-Command "npm")) {
    throw "npm is required to install Claude CLI. Install Node.js first."
  }
  Write-Host "Installing Claude Code CLI..."
  npm install -g @anthropic-ai/claude-code@latest | Out-Null
}

Write-Host ""
Write-Host "Setup complete."
Write-Host "Run: .\relay.ps1 run"
