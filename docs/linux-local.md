# Linux Local Box Guide

This is the guide for running OpenClaw on a local Linux machine — a desktop, mini PC, old laptop, whatever you've got sitting on your desk or in a closet. This is our actual setup (Linux Mint), and it's the most complete backup story because you have physical access and full control.

## What to Backup

| Item | Default Path | Priority |
|------|-------------|----------|
| OpenClaw home | `~/.openclaw/` | 🔴 Critical |
| Workspace | `~/hub-local/` | 🔴 Critical |
| SQLite databases | Inside `~/.openclaw/` | 🔴 Critical |
| Environment/credentials | `.env` files, API keys | 🔴 Critical |
| Custom scripts | Various | 🟡 Important |
| System packages | `dpkg --get-selections` | 🟢 Nice to have |
| Cron jobs | `crontab -l` | 🟢 Nice to have |

## Prerequisites

```bash
# Ubuntu/Debian/Mint
sudo apt update
sudo apt install -y git nodejs npm sqlite3 borgbackup fsarchiver

# Fedora
sudo dnf install -y git nodejs sqlite borgbackup fsarchiver

# Arch
sudo pacman -S git nodejs npm sqlite borg fsarchiver
```

## Tier 1: Git Backup (Hourly)

The fastest way to protect yourself. Takes 5 minutes to set up.

### Setup

```bash
# Make sure your workspace is a git repo
cd ~/hub-local
git init  # skip if already a repo
git remote add origin git@github.com:YOUR_USERNAME/YOUR_REPO.git

# Copy the backup script
cp /path/to/openclaw-backup-guide/scripts/common/backup-db.js ~/hub-local/

# Create .gitignore if needed
cat >> .gitignore << 'EOF'
node_modules/
*.log
*.tmp
.env
EOF

# Test it
cd /path/to/openclaw-backup-guide
source .env
./scripts/linux/backup-git.sh
```

### What Happens

1. `backup-db.js` uses SQLite's `.backup()` API to safely snapshot all databases into `$BACKUP_DIR/db/`
2. `git add -A` stages everything (including the DB snapshots)
3. `git commit` with a timestamp
4. `git push` to your remote

### Automate It

```bash
# Add to crontab (every hour)
(crontab -l 2>/dev/null; echo "0 * * * * cd ~/hub-local && ~/openclaw-backup-guide/scripts/linux/backup-git.sh >> ~/logs/openclaw-backup/git.log 2>&1") | crontab -
```

Or run the setup script:
```bash
./scripts/linux/setup-cron.sh
```

## Tier 2: Borg Backup (3x Daily)

Deduplicated, encrypted, incremental file backups. Borg is the gold standard for Linux backups.

### First-Time Setup

```bash
# Set your passphrase (save this somewhere safe!)
export BORG_PASSPHRASE="your-secure-passphrase-here"

# Initialize the repo
borg init --encryption=repokey ~/backups/borg/openclaw

# IMPORTANT: Export and save your key
borg key export ~/backups/borg/openclaw ~/borg-key-openclaw.txt
# Store this key in your password manager, NOT in the backup itself
```

### Run It

```bash
./scripts/linux/backup-borg.sh
```

### What You Get

```bash
# List all backups
borg list ~/backups/borg/openclaw

# See what's in a backup
borg list ~/backups/borg/openclaw::openclaw-2025-01-15T08:00:00

# Mount a backup and browse it
mkdir /tmp/borg-mount
borg mount ~/backups/borg/openclaw::openclaw-2025-01-15T08:00:00 /tmp/borg-mount
ls /tmp/borg-mount  # browse your files
# When done:
borg umount /tmp/borg-mount

# Restore a specific file
borg extract ~/backups/borg/openclaw::openclaw-2025-01-15T08:00:00 home/user/.openclaw/some-file.db
```

### Prune Policy

The script automatically prunes old backups:
- **7 daily** — one per day for the last week
- **4 weekly** — one per week for the last month
- **3 monthly** — one per month for the last quarter

Adjust `KEEP_DAILY`, `KEEP_WEEKLY`, `KEEP_MONTHLY` in `.env`.

## Tier 3: System Image (Monthly)

A full disk image with fsarchiver. Restores your entire system to bare metal — OS, packages, configs, everything.

### Setup

```bash
# Install fsarchiver
sudo apt install fsarchiver

# Find your root partition
lsblk -o NAME,SIZE,MOUNTPOINT
# Usually /dev/sda1 or /dev/nvme0n1p2

# Set in .env
FSARCHIVER_SOURCE="/dev/nvme0n1p2"
FSARCHIVER_TARGET="/mnt/nas/backups/images"  # or any mounted drive
```

### Run It

```bash
sudo ./scripts/linux/backup-image.sh
```

This runs live — no reboot needed. fsarchiver takes a consistent snapshot even while the system is running.

### Restore from Image

```bash
# Boot from a live USB (Ubuntu, Mint, etc.)
# Mount the drive containing your image
mount /dev/sdb1 /mnt

# List what's in the image
fsarchiver archinfo /mnt/backups/images/myhostname-2025-01-15.fsa

# Restore to a partition
fsarchiver restfs /mnt/backups/images/myhostname-2025-01-15.fsa id=0,dest=/dev/nvme0n1p2

# Reinstall GRUB
mount /dev/nvme0n1p2 /target
mount --bind /dev /target/dev
mount --bind /proc /target/proc
mount --bind /sys /target/sys
chroot /target
grub-install /dev/nvme0n1
update-grub
exit
umount -R /target
reboot
```

## Tier 4: Offsite

Get your backups off the machine. Our setup:

1. **GitHub** — Tier 1 git pushes (free)
2. **NAS** — Synology on local network, receives tarballs + Borg repo via `backup-nas.sh`
3. **Cloud** — NAS Cloud Sync copies everything to Google Drive automatically

```bash
# Manual NAS sync
./scripts/linux/backup-nas.sh

# This is also set up as a daily cron job by setup-cron.sh
```

See [offsite.md](offsite.md) for detailed cloud and NAS strategies.

## Monitoring

### Check backup logs
```bash
tail -20 ~/logs/openclaw-backup/git.log
tail -20 ~/logs/openclaw-backup/borg.log
```

### Run verification
```bash
./scripts/common/verify-backup.sh
```

### Quick health check
```bash
# Last git backup
cd ~/hub-local && git log --oneline -5

# Last Borg backup
borg list ~/backups/borg/openclaw --last 3

# Cron is running?
grep openclaw /var/log/syslog | tail -5
# or
journalctl -t CRON | grep openclaw | tail -5
```

### Set up email alerts (optional)

Add to your `.env`:
```bash
NOTIFY_ON_FAILURE="true"
NOTIFY_METHOD="email"
NOTIFY_EMAIL="you@example.com"
```

Or use a simple monitoring approach — add this to cron:
```bash
# Alert if no git commit in last 2 hours
0 */2 * * * cd ~/hub-local && [ $(git log -1 --format=%ct) -lt $(($(date +%s) - 7200)) ] && echo "OpenClaw backup may be stalled" | mail -s "Backup Alert" you@example.com
```

## Complete Setup (TL;DR)

```bash
# 1. Clone this repo
git clone https://github.com/your-org/openclaw-backup-guide.git ~/openclaw-backup-guide

# 2. Configure
cd ~/openclaw-backup-guide
cp .env.example .env
nano .env  # edit paths, passphrase, NAS target

# 3. Initialize Borg
source .env
borg init --encryption=repokey $BORG_REPO
borg key export $BORG_REPO ~/borg-key-openclaw.txt  # SAVE THIS

# 4. Install cron jobs
./scripts/linux/setup-cron.sh

# 5. Run initial backup
./scripts/linux/backup-git.sh
./scripts/linux/backup-borg.sh

# 6. Verify
./scripts/common/verify-backup.sh
```

---

*Next: [Restore Guide](restore.md) — read it before you need it.*
