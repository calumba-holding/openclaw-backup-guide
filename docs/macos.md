# macOS (Mac Mini) Guide

Running OpenClaw on a Mac Mini? Excellent choice — low power, always-on, and Apple Silicon eats through Node.js workloads. Here's how to make sure you don't lose everything when (not if) something goes wrong.

## iCloud Is NOT a Backup Strategy

Let's get this out of the way: **iCloud is not a backup.** It's sync. If you delete a file, iCloud helpfully deletes it everywhere. If ransomware encrypts your Desktop, iCloud syncs the encrypted files to all your devices. Thanks, Apple.

iCloud is great for photos and Notes. It is not a backup strategy for your OpenClaw installation. Moving on.

## What to Backup

| Item | Default Path | Priority |
|------|-------------|----------|
| OpenClaw home | `~/.openclaw/` | 🔴 Critical |
| Workspace | `~/hub-local/` | 🔴 Critical |
| SQLite databases | Inside `~/.openclaw/` | 🔴 Critical |
| Environment/credentials | `.env` files, API keys | 🔴 Critical |
| Custom scripts | Various | 🟡 Important |
| Homebrew packages | `brew list` | 🟢 Nice to have |
| launchd jobs | `~/Library/LaunchAgents/` | 🟢 Nice to have |

## Prerequisites

Everything installs via [Homebrew](https://brew.sh/). If you don't have Homebrew yet, what are you even doing on macOS?

```bash
# Install Homebrew (if you somehow don't have it)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install everything we need
brew install git node sqlite restic

# Verify
git --version
node --version
restic version
```

### Why restic Over Borg on macOS?

On Linux, Borg is king. On macOS, **restic wins**:

- **No FUSE dependency.** Borg's `mount` command needs macFUSE, which is a kernel extension Apple keeps making harder to install. Every macOS update breaks it. Life's too short.
- **Native macOS binary.** `brew install restic` and you're done. No Python, no dependencies.
- **Built-in remote backends.** restic speaks S3, B2, SFTP natively. No rclone needed (though it works with rclone too).
- **Same deduplication and encryption.** You're not giving anything up.

## One-Command Setup

Want to skip the details? Run the setup script:

```bash
cd /path/to/openclaw-backup-guide
./scripts/macos/setup.sh
```

This installs prerequisites, initializes restic, sets up launchd, and runs an initial backup. See `scripts/macos/setup.sh` for exactly what it does — no magic, just automation.

## Tier 1: Git Backup (Hourly)

Same concept as Linux — snapshot your databases safely, commit everything, push to GitHub.

### Setup

```bash
# Make sure your workspace is a git repo
cd ~/hub-local
git init  # skip if already a repo
git remote add origin git@github.com:YOUR_USERNAME/YOUR_REPO.git

# Test it
cd /path/to/openclaw-backup-guide
source .env
./scripts/macos/backup-git.sh
```

### What `backup-git.sh` Does

1. Adds `/opt/homebrew/bin` to PATH (launchd doesn't inherit your shell's PATH — this is the #1 reason macOS backup scripts fail silently)
2. Runs `backup-db.js` to safely snapshot SQLite databases via the `.backup()` API
3. `git add -A && git commit && git push`

### Automate with launchd

**Use launchd, not cron.** This is macOS — cron jobs don't run if your Mac is asleep. launchd catches up on missed jobs when the machine wakes. Your Mac Mini will sleep sometimes (power naps, lid close on laptops, etc.). launchd handles this gracefully.

```bash
# Copy the plist to LaunchAgents
cp scripts/macos/setup-launchd.plist ~/Library/LaunchAgents/com.openclaw.backup.plist

# Edit the path inside the plist to match your setup
nano ~/Library/LaunchAgents/com.openclaw.backup.plist

# Load it
launchctl load ~/Library/LaunchAgents/com.openclaw.backup.plist

# Verify it's running
launchctl list | grep openclaw
```

The plist (`scripts/macos/setup-launchd.plist`) is configured to:
- Run every 3600 seconds (1 hour)
- Run immediately on load (`RunAtLoad`) — catches up after sleep/restart
- Include Homebrew in PATH (so `git`, `node`, etc. are found)
- Throttle to 5 minutes between retries if something fails

Or just let `setup.sh` do all of this for you.

### launchd Troubleshooting

```bash
# Check if it's loaded
launchctl list | grep openclaw

# Check logs
cat /tmp/openclaw-backup.stdout.log
cat /tmp/openclaw-backup.stderr.log

# Unload and reload
launchctl unload ~/Library/LaunchAgents/com.openclaw.backup.plist
launchctl load ~/Library/LaunchAgents/com.openclaw.backup.plist

# Trigger it manually right now
launchctl start com.openclaw.backup
```

**Common issue:** "Operation not permitted" — go to System Preferences → Privacy & Security → Full Disk Access, and add Terminal (or whatever app runs the script).

## Tier 2: restic Backup (3x Daily)

Deduplicated, encrypted, incremental file backups. The same protection as Borg on Linux, just with a tool that plays nicer with macOS.

### First-Time Setup

```bash
# Set your passphrase (SAVE THIS — you need it to restore)
export RESTIC_PASSWORD="your-secure-passphrase-here"

# Initialize the repo
restic init -r ~/backups/restic/openclaw

# Save the password in your password manager. Not in a sticky note.
# Not in a file on the same machine. In your PASSWORD MANAGER.
```

### Run It

```bash
./scripts/macos/backup-restic.sh
```

### What `backup-restic.sh` Does

1. Snapshots databases via `backup-db.js`
2. Runs `restic backup` on `~/.openclaw`, `~/hub-local`, and DB snapshots
3. Excludes `node_modules`, `.git`, `.DS_Store`, logs, temp files
4. Prunes old snapshots (7 daily, 4 weekly, 3 monthly)
5. Runs a quick integrity check
6. Optionally syncs to a remote repo (`RESTIC_REMOTE_REPO` in `.env`)

### Working with restic Snapshots

```bash
# List all snapshots
restic -r ~/backups/restic/openclaw snapshots

# Restore a specific file
restic -r ~/backups/restic/openclaw restore latest --target /tmp/restore --include "/.openclaw/some-file.db"

# Restore everything
restic -r ~/backups/restic/openclaw restore latest --target /tmp/full-restore

# Diff between snapshots
restic -r ~/backups/restic/openclaw diff SNAPSHOT_ID_1 SNAPSHOT_ID_2
```

Note: No `mount` command needed. restic can mount on macOS via macFUSE, but you don't need to — `restic restore` and `restic dump` get files out without it.

### Automate It

Add a second launchd plist, or add restic to `setup.sh`. For 3x daily:

```bash
# Quick approach: add to crontab (yes, cron works for this if your Mac Mini is always awake)
(crontab -l 2>/dev/null; echo "0 8,14,22 * * * /path/to/scripts/macos/backup-restic.sh >> ~/Library/Logs/openclaw-backup/restic.log 2>&1") | crontab -
```

If your Mac sleeps, create a second launchd plist with `StartInterval` of 28800 (8 hours) instead.

## Tier 3: Time Machine (System Image)

Time Machine is genuinely good at what it does — hourly snapshots of your entire system with bare-metal restore. It's built in, it works, and Apple's restore process is one of the best in the industry. Use it.

**But it's not sufficient alone** because:
- It doesn't do offsite (the drive is right next to your Mac)
- It doesn't safely snapshot SQLite databases (that's what our Tier 1 and 2 handle)
- If someone steals your Mac, they steal the Time Machine drive too

### Setup

1. **Get an external SSD.** USB-C or Thunderbolt. Samsung T7 Shield or SanDisk Extreme Pro are solid choices. Get one that's at least 2x your internal disk size.
2. **Plug it in.** macOS will ask if you want to use it for Time Machine. Say yes.
3. **Enable encryption.** Check the box. Always.
4. **Leave it plugged in.** Time Machine does the rest — hourly backups, automatic pruning.

### Verify with Our Script

```bash
# Check Time Machine status
./scripts/macos/backup-timemachine.sh --status

# Trigger a manual backup
./scripts/macos/backup-timemachine.sh
```

`backup-timemachine.sh` checks that Time Machine is configured, shows the last backup time, and can trigger a manual backup. It'll yell at you if Time Machine isn't set up.

### External SSD Recommendations

| Drive | Interface | Capacity | Why |
|-------|-----------|----------|-----|
| Samsung T7 Shield | USB-C 3.2 | 1-4 TB | Rugged, fast, reliable |
| SanDisk Extreme Pro | USB-C 3.2 | 1-4 TB | Good all-rounder |
| OWC Envoy Pro FX | Thunderbolt/USB-C | 1-4 TB | Thunderbolt speed if you need it |

Get the 2TB. They're cheap insurance. Encrypt it.

## Tier 4: Offsite

Get your backups off the Mac:

1. **GitHub** — Tier 1 git pushes (free, automatic, every hour)
2. **restic to remote** — Set `RESTIC_REMOTE_REPO` in `.env` to a B2 bucket, S3 bucket, or SFTP server. The `backup-restic.sh` script handles the sync.
3. **Time Machine** — Covers local catastrophic failure, not offsite
4. **NAS** — If you have a Synology, set up Cloud Sync to push to Google Drive or B2 automatically

See [offsite.md](offsite.md) for the full strategy.

## Monitoring

### Check backup logs

```bash
# Logs live in ~/Library/Logs/openclaw-backup/
tail -20 ~/Library/Logs/openclaw-backup/git.log
tail -20 ~/Library/Logs/openclaw-backup/restic.log
```

### Quick health check

```bash
# Last git backup
cd ~/hub-local && git log --oneline -5

# Last restic snapshot
restic -r ~/backups/restic/openclaw snapshots --last 3

# Time Machine status
tmutil latestbackup

# launchd job running?
launchctl list | grep openclaw
```

### Run verification

```bash
./scripts/common/verify-backup.sh
```

## Complete Setup (TL;DR)

```bash
# 1. Clone this repo
git clone https://github.com/your-org/openclaw-backup-guide.git ~/openclaw-backup-guide

# 2. Run setup
cd ~/openclaw-backup-guide
cp .env.example .env
nano .env  # set OPENCLAW_HOME, OPENCLAW_WORKSPACE, RESTIC_PASSWORD
./scripts/macos/setup.sh

# 3. Set up Time Machine
# Plug in external SSD → System Preferences → Time Machine → Select Disk → Encrypt

# 4. Verify
./scripts/common/verify-backup.sh
```

---

*Next: [Restore Guide](restore.md) — read it before you need it.*
