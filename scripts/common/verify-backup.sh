#!/usr/bin/env bash
# =============================================================================
# Verify Backup Integrity
# =============================================================================
# Checks that your backups are actually usable. Run this periodically.
# A backup you can't restore is not a backup.
#
# Usage: ./verify-backup.sh
# Exit codes: 0 = all good, 1 = something's wrong
# =============================================================================
set -euo pipefail

# Load config
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/openclaw}"
LOG_DIR="${LOG_DIR:-$HOME/logs/openclaw-backup}"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/verify.log"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"; }
fail() { log "✗ FAIL: $*"; FAILURES=$((FAILURES + 1)); }
pass() { log "✓ PASS: $*"; }

FAILURES=0
CHECKS=0

log "========================================="
log "Backup Verification Starting"
log "========================================="

# ---------------------------------------------------------------------------
# Check 1: Do backup directories exist?
# ---------------------------------------------------------------------------
CHECKS=$((CHECKS + 1))
if [[ -d "$BACKUP_DIR/db" ]]; then
  pass "Backup directory exists: $BACKUP_DIR/db"
else
  fail "Backup directory missing: $BACKUP_DIR/db"
fi

# ---------------------------------------------------------------------------
# Check 2: Are there recent database backups?
# ---------------------------------------------------------------------------
CHECKS=$((CHECKS + 1))
if [[ -d "$BACKUP_DIR/db" ]]; then
  RECENT=$(find "$BACKUP_DIR/db" -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" 2>/dev/null | head -1)
  if [[ -n "$RECENT" ]]; then
    AGE_HOURS=$(( ($(date +%s) - $(stat -c %Y "$RECENT" 2>/dev/null || stat -f %m "$RECENT" 2>/dev/null)) / 3600 ))
    if [[ $AGE_HOURS -le 24 ]]; then
      pass "Database backup is recent (${AGE_HOURS}h old)"
    else
      fail "Database backup is stale (${AGE_HOURS}h old — should be <24h)"
    fi
  else
    fail "No database backup files found"
  fi
fi

# ---------------------------------------------------------------------------
# Check 3: SQLite integrity check on backup files
# ---------------------------------------------------------------------------
if command -v sqlite3 &>/dev/null; then
  for DB_FILE in "$BACKUP_DIR/db"/*.db "$BACKUP_DIR/db"/*.sqlite "$BACKUP_DIR/db"/*.sqlite3; do
    [[ -f "$DB_FILE" ]] || continue
    CHECKS=$((CHECKS + 1))
    RESULT=$(sqlite3 "$DB_FILE" "PRAGMA integrity_check;" 2>&1)
    if [[ "$RESULT" == "ok" ]]; then
      SIZE=$(du -h "$DB_FILE" | cut -f1)
      pass "$(basename "$DB_FILE") integrity OK ($SIZE)"
    else
      fail "$(basename "$DB_FILE") integrity FAILED: $RESULT"
    fi
  done
else
  log "⚠ sqlite3 not found — skipping integrity checks"
fi

# ---------------------------------------------------------------------------
# Check 4: Git remote is reachable
# ---------------------------------------------------------------------------
CHECKS=$((CHECKS + 1))
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/hub-local}"
if [[ -d "$WORKSPACE/.git" ]]; then
  GIT_REMOTE="${GIT_REMOTE:-origin}"
  if cd "$WORKSPACE" && git ls-remote "$GIT_REMOTE" HEAD &>/dev/null; then
    LAST_PUSH=$(git log "$GIT_REMOTE/$GIT_BRANCH" -1 --format="%cr" 2>/dev/null || echo "unknown")
    pass "Git remote '$GIT_REMOTE' is reachable (last push: $LAST_PUSH)"
  else
    fail "Git remote '$GIT_REMOTE' is not reachable"
  fi
else
  log "⚠ No git repo at $WORKSPACE — skipping git check"
fi

# ---------------------------------------------------------------------------
# Check 5: Borg repo (Linux)
# ---------------------------------------------------------------------------
if command -v borg &>/dev/null; then
  BORG_REPO="${BORG_REPO:-$HOME/backups/borg/openclaw}"
  if [[ -d "$BORG_REPO" ]]; then
    CHECKS=$((CHECKS + 1))
    if BORG_PASSPHRASE="${BORG_PASSPHRASE:-}" borg info "$BORG_REPO" &>/dev/null; then
      LAST_ARCHIVE=$(BORG_PASSPHRASE="${BORG_PASSPHRASE:-}" borg list "$BORG_REPO" --last 1 --format "{time}" 2>/dev/null)
      pass "Borg repo OK (last archive: $LAST_ARCHIVE)"
    else
      fail "Borg repo exists but failed info check"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Check 6: Restic repo (macOS)
# ---------------------------------------------------------------------------
if command -v restic &>/dev/null; then
  RESTIC_REPO="${RESTIC_REPO:-$HOME/backups/restic/openclaw}"
  RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
  if [[ -d "$RESTIC_REPO" ]] && [[ -n "$RESTIC_PASSWORD" ]]; then
    CHECKS=$((CHECKS + 1))
    if RESTIC_PASSWORD="$RESTIC_PASSWORD" restic -r "$RESTIC_REPO" snapshots --latest 1 &>/dev/null; then
      pass "Restic repo OK"
    else
      fail "Restic repo exists but failed check"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Check 7: NAS reachability
# ---------------------------------------------------------------------------
if [[ -n "${NAS_TARGET:-}" ]]; then
  CHECKS=$((CHECKS + 1))
  NAS_HOST=$(echo "$NAS_TARGET" | cut -d: -f1 | cut -d@ -f2)
  NAS_PORT="${NAS_SSH_PORT:-22}"
  if ssh -p "$NAS_PORT" -o ConnectTimeout=5 -o BatchMode=yes "$NAS_TARGET" "echo ok" &>/dev/null; then
    pass "NAS is reachable at $NAS_HOST"
  else
    # Try just ping
    if ping -c 1 -W 3 "$NAS_HOST" &>/dev/null; then
      pass "NAS is pingable (SSH may need key setup)"
    else
      fail "NAS is not reachable at $NAS_HOST"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log ""
log "========================================="
if [[ $FAILURES -eq 0 ]]; then
  log "ALL $CHECKS CHECKS PASSED ✓"
else
  log "$FAILURES/$CHECKS CHECKS FAILED ✗"
fi
log "========================================="

exit $([[ $FAILURES -eq 0 ]] && echo 0 || echo 1)
