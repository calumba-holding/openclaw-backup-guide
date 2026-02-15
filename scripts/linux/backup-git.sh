#!/usr/bin/env bash
# =============================================================================
# Tier 1: Git Backup
# =============================================================================
# 1. Safely snapshot SQLite databases
# 2. git add -A && git commit && git push
#
# Run hourly via cron. Idempotent — skips commit if nothing changed.
#
# Usage: ./backup-git.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load config
ENV_FILE="${SCRIPT_DIR}/../../.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/hub-local}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-main}"
LOG_DIR="${LOG_DIR:-$HOME/logs/openclaw-backup}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/git.log"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"; }

log "--- Git backup starting ---"

# Step 1: Safe SQLite backup
log "Snapshotting databases..."
if command -v node &>/dev/null; then
  node "$SCRIPT_DIR/../common/backup-db.js" 2>&1 | tee -a "$LOG_FILE"
else
  log "WARNING: Node.js not found. Skipping database snapshot."
  log "Install Node.js or set PATH to include it."
fi

# Step 2: Git commit and push
cd "$OPENCLAW_WORKSPACE"

if [[ ! -d .git ]]; then
  log "ERROR: $OPENCLAW_WORKSPACE is not a git repository."
  log "Initialize with: git init && git remote add origin <your-repo-url>"
  exit 1
fi

# Check if there are changes
if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
  log "No changes to commit. Skipping."
  exit 0
fi

# Stage everything
git add -A

# Commit with timestamp
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
HOSTNAME="$(hostname)"
git commit -m "backup: ${TIMESTAMP} [${HOSTNAME}]" --no-verify 2>&1 | tee -a "$LOG_FILE"

# Push
if git push "$GIT_REMOTE" "$GIT_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
  log "✓ Git backup complete — committed and pushed."
else
  log "✗ Push failed. Commit is local only. Check your remote config."
  exit 1
fi
