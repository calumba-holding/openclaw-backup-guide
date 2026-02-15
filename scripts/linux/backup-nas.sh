#!/usr/bin/env bash
# =============================================================================
# Tier 4 (partial): Backup to NAS via SCP
# =============================================================================
# Tars up critical files and SCPs them to a NAS. Also syncs the Borg repo.
#
# Usage: ./backup-nas.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../../.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/hub-local}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/openclaw}"
BORG_REPO="${BORG_REPO:-$HOME/backups/borg/openclaw}"
NAS_TARGET="${NAS_TARGET:-}"
NAS_SSH_PORT="${NAS_SSH_PORT:-22}"
NAS_SSH_KEY="${NAS_SSH_KEY:-}"
LOG_DIR="${LOG_DIR:-$HOME/logs/openclaw-backup}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/nas.log"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"; }

if [[ -z "$NAS_TARGET" ]]; then
  log "ERROR: NAS_TARGET not set. Set it in .env (e.g., admin@nas.local:/volume1/backups/openclaw)"
  exit 1
fi

SSH_OPTS="-p $NAS_SSH_PORT -o ConnectTimeout=10 -o BatchMode=yes"
if [[ -n "$NAS_SSH_KEY" ]]; then
  SSH_OPTS="$SSH_OPTS -i $NAS_SSH_KEY"
fi

log "--- NAS backup starting ---"

# ---------------------------------------------------------------------------
# Step 1: Create tarball of critical files
# ---------------------------------------------------------------------------
TIMESTAMP="$(date +%Y-%m-%d_%H%M%S)"
TAR_FILE="$BACKUP_DIR/openclaw-snapshot-${TIMESTAMP}.tar.gz"

log "Creating tarball..."
mkdir -p "$BACKUP_DIR"
tar czf "$TAR_FILE" \
  --exclude='node_modules' \
  --exclude='.git' \
  --exclude='*.log' \
  -C "$(dirname "$OPENCLAW_HOME")" "$(basename "$OPENCLAW_HOME")" \
  -C "$(dirname "$BACKUP_DIR/db")" "db" \
  2>&1 | tee -a "$LOG_FILE"

TAR_SIZE=$(du -h "$TAR_FILE" | cut -f1)
log "Tarball created: $TAR_FILE ($TAR_SIZE)"

# ---------------------------------------------------------------------------
# Step 2: SCP tarball to NAS
# ---------------------------------------------------------------------------
log "Uploading tarball to NAS..."
# Ensure remote directory exists
NAS_HOST_PART=$(echo "$NAS_TARGET" | cut -d: -f1)
NAS_PATH_PART=$(echo "$NAS_TARGET" | cut -d: -f2)
ssh $SSH_OPTS "$NAS_HOST_PART" "mkdir -p '$NAS_PATH_PART'" 2>&1 | tee -a "$LOG_FILE"

scp $SSH_OPTS "$TAR_FILE" "$NAS_TARGET/" 2>&1 | tee -a "$LOG_FILE"
log "✓ Tarball uploaded to NAS"

# ---------------------------------------------------------------------------
# Step 3: Sync Borg repo to NAS (if it exists)
# ---------------------------------------------------------------------------
if [[ -d "$BORG_REPO" ]]; then
  log "Syncing Borg repo to NAS..."
  rsync -avz --delete \
    -e "ssh $SSH_OPTS" \
    "$BORG_REPO/" \
    "$NAS_TARGET/borg/" \
    2>&1 | tee -a "$LOG_FILE"
  log "✓ Borg repo synced to NAS"
fi

# ---------------------------------------------------------------------------
# Step 4: Clean up old local tarballs (keep last 3)
# ---------------------------------------------------------------------------
log "Cleaning up old local tarballs..."
ls -t "$BACKUP_DIR"/openclaw-snapshot-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
log "Local cleanup done"

# ---------------------------------------------------------------------------
# Step 5: Clean up old remote tarballs (keep last 7)
# ---------------------------------------------------------------------------
log "Cleaning up old remote tarballs..."
ssh $SSH_OPTS "$NAS_HOST_PART" "cd '$NAS_PATH_PART' && ls -t openclaw-snapshot-*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f" 2>&1 | tee -a "$LOG_FILE"
log "Remote cleanup done"

log "✓ NAS backup complete"
