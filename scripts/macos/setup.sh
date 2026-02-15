#!/usr/bin/env bash
# =============================================================================
# One-Command macOS Setup
# =============================================================================
# Sets up the complete OpenClaw backup stack on macOS.
#
# Usage: ./setup.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "🛡️  OpenClaw Backup Setup for macOS"
echo "===================================="
echo ""

# ---------------------------------------------------------------------------
# Step 1: Check prerequisites
# ---------------------------------------------------------------------------
echo "Checking prerequisites..."

# Homebrew
if ! command -v brew &>/dev/null; then
  echo "❌ Homebrew not found. Install it first:"
  echo '   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  exit 1
fi
echo "  ✓ Homebrew"

# Node.js
if ! command -v node &>/dev/null; then
  echo "  Installing Node.js..."
  brew install node
fi
echo "  ✓ Node.js $(node --version)"

# Git
if ! command -v git &>/dev/null; then
  echo "  Installing git..."
  brew install git
fi
echo "  ✓ Git $(git --version | cut -d' ' -f3)"

# sqlite3
if ! command -v sqlite3 &>/dev/null; then
  brew install sqlite
fi
echo "  ✓ SQLite3"

# restic
if ! command -v restic &>/dev/null; then
  echo "  Installing restic..."
  brew install restic
fi
echo "  ✓ restic $(restic version | cut -d' ' -f2)"

echo ""

# ---------------------------------------------------------------------------
# Step 2: Configuration
# ---------------------------------------------------------------------------
ENV_FILE="$REPO_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Creating configuration file..."
  cp "$REPO_DIR/.env.example" "$ENV_FILE"
  
  # Set macOS-specific defaults
  sed -i '' "s|LOG_DIR=.*|LOG_DIR=\"\${HOME}/Library/Logs/openclaw-backup\"|" "$ENV_FILE"
  
  echo "  ✓ Created $ENV_FILE"
  echo ""
  echo "⚠️  IMPORTANT: Edit $ENV_FILE before continuing!"
  echo "   At minimum, set:"
  echo "   - OPENCLAW_HOME (where OpenClaw is installed)"
  echo "   - OPENCLAW_WORKSPACE (your workspace directory)"
  echo "   - RESTIC_PASSWORD (pick something strong)"
  echo ""
  read -p "Press Enter after editing .env (or Ctrl-C to abort)..."
fi

source "$ENV_FILE"

# ---------------------------------------------------------------------------
# Step 3: Create directories
# ---------------------------------------------------------------------------
echo "Creating directories..."
mkdir -p "${BACKUP_DIR:-$HOME/backups/openclaw}/db"
mkdir -p "${LOG_DIR:-$HOME/Library/Logs/openclaw-backup}"
echo "  ✓ Directories created"

# ---------------------------------------------------------------------------
# Step 4: Initialize restic repo
# ---------------------------------------------------------------------------
RESTIC_REPO="${RESTIC_REPO:-$HOME/backups/restic/openclaw}"
if [[ ! -d "$RESTIC_REPO" ]]; then
  echo "Initializing restic repository..."
  export RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
  if [[ -z "$RESTIC_PASSWORD" ]]; then
    echo "❌ RESTIC_PASSWORD not set in .env"
    exit 1
  fi
  restic init -r "$RESTIC_REPO"
  echo "  ✓ Restic repo initialized at $RESTIC_REPO"
fi

# ---------------------------------------------------------------------------
# Step 5: Make scripts executable
# ---------------------------------------------------------------------------
echo "Setting permissions..."
chmod +x "$SCRIPT_DIR"/*.sh
chmod +x "$SCRIPT_DIR/../common"/*.sh
echo "  ✓ Scripts are executable"

# ---------------------------------------------------------------------------
# Step 6: Install launchd job
# ---------------------------------------------------------------------------
PLIST_NAME="com.openclaw.backup.plist"
PLIST_SRC="$SCRIPT_DIR/setup-launchd.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"

echo "Installing launchd job..."

# Update the plist with actual paths
sed "s|\$HOME/openclaw-backup-guide/scripts/macos/backup-git.sh|$SCRIPT_DIR/backup-git.sh|g" \
  "$PLIST_SRC" > "$PLIST_DST"

# Load it
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "  ✓ launchd job installed (hourly git backup)"

# ---------------------------------------------------------------------------
# Step 7: Run initial backup
# ---------------------------------------------------------------------------
echo ""
echo "Running initial backup..."
"$SCRIPT_DIR/backup-git.sh" && echo "  ✓ Initial git backup complete" || echo "  ⚠ Initial backup had issues — check logs"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "===================================="
echo "🎉 Setup complete!"
echo "===================================="
echo ""
echo "What's running:"
echo "  • Tier 1 (Git): Every hour via launchd"
echo "  • Tier 2 (restic): Run manually or add to launchd"
echo "  • Tier 3 (Time Machine): Configure in System Preferences"
echo ""
echo "Useful commands:"
echo "  ./backup-git.sh           # Manual git backup"
echo "  ./backup-restic.sh        # Manual restic backup"
echo "  ./backup-timemachine.sh   # Check Time Machine status"
echo "  ../common/verify-backup.sh # Verify backup integrity"
echo ""
echo "Logs: ${LOG_DIR:-$HOME/Library/Logs/openclaw-backup}/"
