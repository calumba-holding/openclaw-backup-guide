#!/usr/bin/env bash
# =============================================================================
# Tier 2: Restic Backup (macOS)
# =============================================================================
# Restic over Borg for macOS because:
# - No FUSE dependency (FUSE on macOS is a pain)
# - Native macOS support, well-maintained
# - Easy remote backends (S3, B2, SFTP built-in)
#
# Prerequisites: brew install restic
# First run: restic init -r $RESTIC_REPO
#
# Usage: ./backup-restic.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../../.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/hub-local}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/openclaw}"
RESTIC_REPO="${RESTIC_REPO:-$HOME/backups/restic/openclaw}"
export RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
RESTIC_REMOTE_REPO="${RESTIC_REMOTE_REPO:-}"

KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-3}"

LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/openclaw-backup}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/restic.log"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

# Preflight
if ! command -v restic &>/dev/null; then
  log "ERROR: restic not found. Install with: brew install restic"
  exit 1
fi

if [[ -z "$RESTIC_PASSWORD" ]]; then
  log "ERROR: RESTIC_PASSWORD not set."
  exit 1
fi

# Initialize repo if needed
if ! restic -r "$RESTIC_REPO" snapshots --latest 1 &>/dev/null 2>&1; then
  log "Initializing new restic repo at $RESTIC_REPO..."
  restic init -r "$RESTIC_REPO" 2>&1 | tee -a "$LOG_FILE"
fi

log "--- Restic backup starting ---"

# Snapshot databases first
if command -v node &>/dev/null; then
  node "$SCRIPT_DIR/../common/backup-db.js" 2>&1 | tee -a "$LOG_FILE"
fi

# Create backup
restic backup \
  --verbose \
  --tag openclaw \
  --exclude='node_modules' \
  --exclude='.git' \
  --exclude='*.log' \
  --exclude='*.tmp' \
  --exclude='.DS_Store' \
  -r "$RESTIC_REPO" \
  "$OPENCLAW_HOME" \
  "$OPENCLAW_WORKSPACE" \
  "$BACKUP_DIR/db" \
  2>&1 | tee -a "$LOG_FILE"

# Prune
log "Pruning old snapshots..."
restic forget \
  --prune \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  --tag openclaw \
  -r "$RESTIC_REPO" \
  2>&1 | tee -a "$LOG_FILE"

# Check integrity (quick)
log "Quick integrity check..."
restic check -r "$RESTIC_REPO" 2>&1 | tee -a "$LOG_FILE"

# Sync to remote if configured
if [[ -n "$RESTIC_REMOTE_REPO" ]]; then
  log "Syncing to remote: $RESTIC_REMOTE_REPO"
  restic copy \
    --from-repo "$RESTIC_REPO" \
    -r "$RESTIC_REMOTE_REPO" \
    --tag openclaw \
    2>&1 | tee -a "$LOG_FILE"
fi

REPO_SIZE=$(du -sh "$RESTIC_REPO" | cut -f1)
log "✓ Restic backup complete. Repo size: $REPO_SIZE"
