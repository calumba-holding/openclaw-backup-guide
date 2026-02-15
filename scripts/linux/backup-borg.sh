#!/usr/bin/env bash
# =============================================================================
# Tier 2: Borg Backup (File-Level, Deduplicated, Encrypted)
# =============================================================================
# Creates an incremental, deduplicated, encrypted backup of your OpenClaw
# installation using Borg. Prunes old archives per retention policy.
#
# Prerequisites: sudo apt install borgbackup
# First run: borg init --encryption=repokey $BORG_REPO
#
# Usage: ./backup-borg.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load config
ENV_FILE="${SCRIPT_DIR}/../../.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/hub-local}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/openclaw}"
BORG_REPO="${BORG_REPO:-$HOME/backups/borg/openclaw}"
export BORG_PASSPHRASE="${BORG_PASSPHRASE:-}"
BORG_REMOTE_REPO="${BORG_REMOTE_REPO:-}"

KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-3}"

LOG_DIR="${LOG_DIR:-$HOME/logs/openclaw-backup}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/borg.log"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if ! command -v borg &>/dev/null; then
  log "ERROR: borg not found. Install with: sudo apt install borgbackup"
  exit 1
fi

if [[ -z "$BORG_PASSPHRASE" ]]; then
  log "ERROR: BORG_PASSPHRASE not set. Set it in .env or environment."
  exit 1
fi

# Initialize repo if it doesn't exist
if [[ ! -d "$BORG_REPO" ]]; then
  log "Initializing new Borg repo at $BORG_REPO..."
  borg init --encryption=repokey "$BORG_REPO" 2>&1 | tee -a "$LOG_FILE"
  log "Borg repo initialized. SAVE YOUR PASSPHRASE AND KEY!"
  log "Export key with: borg key export $BORG_REPO /safe/location/borg.key"
fi

# ---------------------------------------------------------------------------
# Step 1: Snapshot databases first
# ---------------------------------------------------------------------------
log "--- Borg backup starting ---"
log "Snapshotting databases..."
if command -v node &>/dev/null; then
  node "$SCRIPT_DIR/../common/backup-db.js" 2>&1 | tee -a "$LOG_FILE"
fi

# ---------------------------------------------------------------------------
# Step 2: Create archive
# ---------------------------------------------------------------------------
ARCHIVE_NAME="openclaw-$(date +%Y-%m-%dT%H:%M:%S)"

log "Creating Borg archive: $ARCHIVE_NAME"

borg create \
  --verbose \
  --filter AME \
  --list \
  --stats \
  --show-rc \
  --compression lz4 \
  --exclude-caches \
  --exclude '*.pyc' \
  --exclude '__pycache__' \
  --exclude 'node_modules' \
  --exclude '.git' \
  --exclude '*.log' \
  --exclude '*.tmp' \
  "$BORG_REPO::$ARCHIVE_NAME" \
  "$OPENCLAW_HOME" \
  "$OPENCLAW_WORKSPACE" \
  "$BACKUP_DIR/db" \
  2>&1 | tee -a "$LOG_FILE"

BACKUP_EXIT=$?

# ---------------------------------------------------------------------------
# Step 3: Prune old archives
# ---------------------------------------------------------------------------
log "Pruning old archives..."

borg prune \
  --list \
  --show-rc \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  "$BORG_REPO" \
  2>&1 | tee -a "$LOG_FILE"

# ---------------------------------------------------------------------------
# Step 4: Compact (Borg 1.2+)
# ---------------------------------------------------------------------------
if borg compact --help &>/dev/null 2>&1; then
  log "Compacting repo..."
  borg compact "$BORG_REPO" 2>&1 | tee -a "$LOG_FILE"
fi

# ---------------------------------------------------------------------------
# Step 5: Sync to remote (optional)
# ---------------------------------------------------------------------------
if [[ -n "$BORG_REMOTE_REPO" ]]; then
  log "Syncing to remote repo: $BORG_REMOTE_REPO"
  # Use borg transfer if available (Borg 2.0+), otherwise rsync the whole repo
  if borg transfer --help &>/dev/null 2>&1; then
    borg transfer --dry-run "$BORG_REPO" "$BORG_REMOTE_REPO" 2>&1 | tee -a "$LOG_FILE"
  else
    rsync -avz --delete "$BORG_REPO/" "$BORG_REMOTE_REPO/" 2>&1 | tee -a "$LOG_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
REPO_SIZE=$(du -sh "$BORG_REPO" | cut -f1)
log "✓ Borg backup complete. Repo size: $REPO_SIZE"

exit $BACKUP_EXIT
