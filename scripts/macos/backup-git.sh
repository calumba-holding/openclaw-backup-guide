#!/usr/bin/env bash
# =============================================================================
# Tier 1: Git Backup (macOS)
# =============================================================================
# Same as Linux version but with macOS path defaults.
# Uses launchd instead of cron (see setup-launchd.plist).
#
# Usage: ./backup-git.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../../.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/hub-local}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-main}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/openclaw-backup}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/git.log"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

log "--- Git backup starting ---"

# Ensure Homebrew tools are in PATH (common macOS issue with launchd)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Step 1: Safe SQLite backup
log "Snapshotting databases..."
if command -v node &>/dev/null; then
  node "$SCRIPT_DIR/../common/backup-db.js" 2>&1 | tee -a "$LOG_FILE"
else
  log "WARNING: Node.js not found. Install with: brew install node"
fi

# Step 2: Git commit and push
cd "$OPENCLAW_WORKSPACE"

if [[ ! -d .git ]]; then
  log "ERROR: $OPENCLAW_WORKSPACE is not a git repository."
  exit 1
fi

if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
  log "No changes to commit. Skipping."
  exit 0
fi

git add -A
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
git commit -m "backup: ${TIMESTAMP} [$(hostname)]" --no-verify 2>&1 | tee -a "$LOG_FILE"

if git push "$GIT_REMOTE" "$GIT_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
  log "✓ Git backup complete."
else
  log "✗ Push failed."
  exit 1
fi
