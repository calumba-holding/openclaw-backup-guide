#!/usr/bin/env bash
# =============================================================================
# Setup All Cron Jobs
# =============================================================================
# Installs cron jobs for all backup tiers. Safe to re-run (idempotent).
#
# Usage: ./setup-cron.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../../.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

LOG_DIR="${LOG_DIR:-$HOME/logs/openclaw-backup}"
OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/hub-local}"

mkdir -p "$LOG_DIR"

echo "=== OpenClaw Backup Cron Setup ==="
echo ""
echo "This will install the following cron jobs:"
echo "  • Tier 1 (Git):    Every hour"
echo "  • Tier 2 (Borg):   3x daily (8am, 2pm, 10pm)"
echo "  • Tier 3 (Image):  1st of each month at 3am (requires sudo)"
echo "  • NAS sync:        Daily at midnight"
echo "  • Verification:    Weekly on Sunday at 6am"
echo ""

# Remove any existing OpenClaw backup entries
EXISTING_CRON=$(crontab -l 2>/dev/null || true)
CLEANED_CRON=$(echo "$EXISTING_CRON" | grep -v "# openclaw-backup" | grep -v "backup-git.sh" | grep -v "backup-borg.sh" | grep -v "backup-nas.sh" | grep -v "verify-backup.sh" || true)

# Build new cron entries
NEW_ENTRIES="
# openclaw-backup: Tier 1 — Git backup (hourly)
0 * * * * cd \"$OPENCLAW_WORKSPACE\" && \"$SCRIPT_DIR/backup-git.sh\" >> \"$LOG_DIR/git.log\" 2>&1

# openclaw-backup: Tier 2 — Borg backup (3x daily)
0 8,14,22 * * * \"$SCRIPT_DIR/backup-borg.sh\" >> \"$LOG_DIR/borg.log\" 2>&1

# openclaw-backup: NAS sync (daily at midnight)
0 0 * * * \"$SCRIPT_DIR/backup-nas.sh\" >> \"$LOG_DIR/nas.log\" 2>&1

# openclaw-backup: Verification (weekly Sunday 6am)
0 6 * * 0 \"$SCRIPT_DIR/../common/verify-backup.sh\" >> \"$LOG_DIR/verify.log\" 2>&1
"

# Install
echo "$CLEANED_CRON$NEW_ENTRIES" | crontab -

echo "✓ Cron jobs installed."
echo ""
echo "Current crontab:"
crontab -l
echo ""

# Tier 3 needs root cron
echo "=== Tier 3 (System Image) ==="
echo "System image backup requires root. To set up monthly image backup:"
echo ""
echo "  sudo crontab -e"
echo ""
echo "Add this line:"
echo "  0 3 1 * * $SCRIPT_DIR/backup-image.sh >> $LOG_DIR/image.log 2>&1"
echo ""

# Verify log directory is writable
if touch "$LOG_DIR/.test" 2>/dev/null; then
  rm -f "$LOG_DIR/.test"
  echo "✓ Log directory is writable: $LOG_DIR"
else
  echo "⚠ WARNING: Cannot write to log directory: $LOG_DIR"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Monitor your backups:"
echo "  tail -f $LOG_DIR/git.log    # Watch git backups"
echo "  tail -f $LOG_DIR/borg.log   # Watch Borg backups"
echo "  cat $LOG_DIR/verify.log     # Check verification results"
