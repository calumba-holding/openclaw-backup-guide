#!/usr/bin/env bash
# =============================================================================
# Tier 3: Time Machine Helpers (macOS)
# =============================================================================
# Time Machine is built into macOS and provides system-level backup.
# This script verifies it's running and optionally triggers a manual backup.
#
# Time Machine is NOT enough on its own (no offsite, no versioned DB snapshots),
# but it's a great Tier 3 — bare-metal recovery from a Time Machine backup is
# genuinely good on macOS.
#
# Usage:
#   ./backup-timemachine.sh          # Check status + trigger backup
#   ./backup-timemachine.sh --status # Just check status
# =============================================================================
set -euo pipefail

LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/openclaw-backup}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/timemachine.log"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

STATUS_ONLY=false
[[ "${1:-}" == "--status" ]] && STATUS_ONLY=true

log "--- Time Machine check ---"

# Check if Time Machine is configured
if ! tmutil destinationinfo &>/dev/null; then
  log "⚠ Time Machine is NOT configured."
  log "Set it up: System Preferences → Time Machine → Select Backup Disk"
  log ""
  log "Recommended setup:"
  log "  • External SSD (USB-C or Thunderbolt) — fast and reliable"
  log "  • 2x your disk size minimum"
  log "  • Encrypt the backup (checkbox in Time Machine setup)"
  exit 1
fi

# Show destination info
log "Time Machine destinations:"
tmutil destinationinfo 2>&1 | tee -a "$LOG_FILE"

# Check last backup
LAST_BACKUP=$(tmutil latestbackup 2>/dev/null || echo "none")
if [[ "$LAST_BACKUP" == "none" ]]; then
  log "⚠ No Time Machine backup found. First backup may take hours."
else
  log "Last backup: $LAST_BACKUP"
  # Check age
  BACKUP_DATE=$(basename "$LAST_BACKUP" | sed 's/-/:/4' | sed 's/-/:/5')
  log "Backup path: $LAST_BACKUP"
fi

# Check if backup is running
TM_STATUS=$(tmutil status 2>/dev/null)
if echo "$TM_STATUS" | grep -q "Running = 1"; then
  PERCENT=$(echo "$TM_STATUS" | grep "Percent" | awk -F= '{print $2}' | tr -d ' ;')
  log "Time Machine is currently running (${PERCENT:-unknown}% complete)"
fi

if $STATUS_ONLY; then
  log "Status check complete."
  exit 0
fi

# Trigger a backup
log "Triggering Time Machine backup..."
tmutil startbackup --auto 2>&1 | tee -a "$LOG_FILE"
log "✓ Time Machine backup triggered (runs in background)."
log "Monitor with: tmutil status"
