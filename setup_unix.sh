#!/usr/bin/env bash
set -euo pipefail

# Cross-platform UNIX setup for Claude Local Relay.
# Supported hosts:
# - macOS (Homebrew)
# - Linux (apt, dnf, yum, pacman, zypper)

INSTALL_LMSTUDIO="false"
INSTALL_CLAUDE="false"

for arg in "$@"; do
  case "$arg" in
    --install-lmstudio) INSTALL_LMSTUDIO="true" ;;
    --install-claude) INSTALL_CLAUDE="true" ;;
    *)
      echo "Unknown argument: $arg"
      echo "Usage: $0 [--install-lmstudio] [--install-claude]"
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_brew_deps() {
  if ! has_cmd brew; then
    echo "Homebrew is required on macOS. Install it from https://brew.sh and run again."
    exit 1
  fi
  echo "Installing dependencies with Homebrew..."
  brew install jq python@3.11 curl >/dev/null
  if [ "$INSTALL_CLAUDE" = "true" ]; then
    brew install node >/dev/null
  fi
  if [ "$INSTALL_LMSTUDIO" = "true" ]; then
    brew install --cask lm-studio >/dev/null || true
  fi
}

ensure_linux_deps() {
  local sudo_cmd=""
  if has_cmd sudo; then
    sudo_cmd="sudo"
  fi

  if has_cmd apt-get; then
    echo "Installing dependencies with apt..."
    $sudo_cmd apt-get update -y >/dev/null
    $sudo_cmd apt-get install -y curl jq python3 python3-venv python3-pip >/dev/null
    if [ "$INSTALL_CLAUDE" = "true" ]; then
      $sudo_cmd apt-get install -y nodejs npm >/dev/null || true
    fi
    return
  fi

  if has_cmd dnf; then
    echo "Installing dependencies with dnf..."
    $sudo_cmd dnf install -y curl jq python3 python3-pip >/dev/null
    if [ "$INSTALL_CLAUDE" = "true" ]; then
      $sudo_cmd dnf install -y nodejs npm >/dev/null || true
    fi
    return
  fi

  if has_cmd yum; then
    echo "Installing dependencies with yum..."
    $sudo_cmd yum install -y curl jq python3 python3-pip >/dev/null
    if [ "$INSTALL_CLAUDE" = "true" ]; then
      $sudo_cmd yum install -y nodejs npm >/dev/null || true
    fi
    return
  fi

  if has_cmd pacman; then
    echo "Installing dependencies with pacman..."
    $sudo_cmd pacman -Sy --noconfirm curl jq python python-pip >/dev/null
    if [ "$INSTALL_CLAUDE" = "true" ]; then
      $sudo_cmd pacman -Sy --noconfirm nodejs npm >/dev/null || true
    fi
    return
  fi

  if has_cmd zypper; then
    echo "Installing dependencies with zypper..."
    $sudo_cmd zypper -n install curl jq python3 python3-pip >/dev/null
    if [ "$INSTALL_CLAUDE" = "true" ]; then
      $sudo_cmd zypper -n install nodejs npm >/dev/null || true
    fi
    return
  fi

  echo "No supported package manager detected."
  echo "Install manually: curl, jq, python3, python3-venv, pip, and optionally node/npm."
  exit 1
}

install_lmstudio_cli_if_requested() {
  if [ "$INSTALL_LMSTUDIO" = "true" ] && ! has_cmd lms; then
    echo "Installing LM Studio CLI..."
    curl -fsSL https://lmstudio.ai/install.sh | bash
    export PATH="$HOME/.lmstudio/bin:$PATH"
  fi
}

setup_python_env() {
  local py_bin="python3"
  if has_cmd python3.11; then
    py_bin="python3.11"
  fi

  if [ ! -d ".venv" ]; then
    "$py_bin" -m venv .venv
  fi

  . .venv/bin/activate
  python -m pip install --upgrade pip >/dev/null
  python -m pip install -r requirements.txt >/dev/null
}

ensure_env_file() {
  if [ ! -f ".env" ]; then
    cp .env.example .env
    echo "Created .env from .env.example"
  fi
}

install_claude_cli_if_requested() {
  if [ "$INSTALL_CLAUDE" != "true" ]; then
    return
  fi
  if has_cmd claude; then
    return
  fi
  if ! has_cmd npm; then
    echo "npm was not found. Install Node.js first, then run:"
    echo "  npm install -g @anthropic-ai/claude-code@latest"
    exit 1
  fi
  echo "Installing Claude Code CLI..."
  npm install -g @anthropic-ai/claude-code@latest >/dev/null
}

os_name="$(uname -s)"
case "$os_name" in
  Darwin)
    ensure_brew_deps
    ;;
  Linux)
    ensure_linux_deps
    ;;
  *)
    echo "Unsupported UNIX platform: $os_name"
    exit 1
    ;;
esac

install_lmstudio_cli_if_requested
setup_python_env
ensure_env_file
install_claude_cli_if_requested

cat <<'EOF'

Setup complete.

Next:
  ./relay run

Or full auto onboarding:
  ./relay bootstrap

EOF
