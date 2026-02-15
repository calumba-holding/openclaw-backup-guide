#!/usr/bin/env bash
# =============================================================================
# Tier 3: Full System Image (fsarchiver)
# =============================================================================
# Creates a full filesystem image that can restore to bare metal.
# Runs live — no reboot needed (fsarchiver handles this safely).
#
# Prerequisites: sudo apt install fsarchiver
# Requires root (or sudo).
#
# Usage: sudo ./backup-image.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../../.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

FSARCHIVER_TARGET="${FSARCHIVER_TARGET:-/mnt/nas/backups/images}"
FSARCHIVER_SOURCE="${FSARCHIVER_SOURCE:-/dev/sda1}"
FSARCHIVER_KEEP="${FSARCHIVER_KEEP:-3}"
LOG_DIR="${LOG_DIR:-$HOME/logs/openclaw-backup}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/image.log"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  log "ERROR: This script must be run as root (or with sudo)."
  exit 1
fi

if ! command -v fsarchiver &>/dev/null; then
  log "ERROR: fsarchiver not found. Install with: sudo apt install fsarchiver"
  exit 1
fi

if [[ ! -b "$FSARCHIVER_SOURCE" ]]; then
  log "ERROR: Source device $FSARCHIVER_SOURCE does not exist."
  log "Find your root partition with: lsblk -o NAME,SIZE,MOUNTPOINT"
  exit 1
fi

if [[ ! -d "$FSARCHIVER_TARGET" ]]; then
  log "ERROR: Target directory $FSARCHIVER_TARGET does not exist."
  log "Mount your NAS or create the directory first."
  exit 1
fi

# ---------------------------------------------------------------------------
# Create image
# ---------------------------------------------------------------------------
TIMESTAMP="$(date +%Y-%m-%d)"
HOSTNAME="$(hostname)"
IMAGE_FILE="${FSARCHIVER_TARGET}/${HOSTNAME}-${TIMESTAMP}.fsa"

log "--- System image backup starting ---"
log "Source: $FSARCHIVER_SOURCE"
log "Target: $IMAGE_FILE"
log "This may take a while..."

# -j4 = use 4 compression threads
# -z3 = medium compression (good balance of speed vs size)
# -A = save extended attributes
fsarchiver savefs \
  -j4 \
  -z3 \
  -A \
  -v \
  "$IMAGE_FILE" \
  "$FSARCHIVER_SOURCE" \
  2>&1 | tee -a "$LOG_FILE"

IMAGE_SIZE=$(du -h "$IMAGE_FILE" | cut -f1)
log "✓ Image created: $IMAGE_FILE ($IMAGE_SIZE)"

# ---------------------------------------------------------------------------
# Verify image
# ---------------------------------------------------------------------------
log "Verifying image integrity..."
if fsarchiver archinfo "$IMAGE_FILE" &>/dev/null; then
  log "✓ Image verification passed"
else
  log "✗ Image verification FAILED — image may be corrupt!"
  exit 1
fi

# ---------------------------------------------------------------------------
# Prune old images
# ---------------------------------------------------------------------------
log "Pruning old images (keeping last $FSARCHIVER_KEEP)..."
ls -t "${FSARCHIVER_TARGET}"/${HOSTNAME}-*.fsa 2>/dev/null | tail -n +$((FSARCHIVER_KEEP + 1)) | while read -r OLD; do
  log "Removing old image: $(basename "$OLD")"
  rm -f "$OLD"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL_SIZE=$(du -sh "$FSARCHIVER_TARGET" | cut -f1)
IMAGE_COUNT=$(ls -1 "${FSARCHIVER_TARGET}"/${HOSTNAME}-*.fsa 2>/dev/null | wc -l)
log "✓ System image backup complete."
log "  Images: $IMAGE_COUNT, Total size: $TOTAL_SIZE"
