# Windows Guide

Running OpenClaw on Windows? Brave. It works great, but the backup tooling is... different. This guide covers the Windows-native approach using PowerShell, robocopy, Veeam, and Task Scheduler. No WSL required (though it helps).

## OneDrive Is NOT a Backup Strategy

Say it with me: **OneDrive is sync, not backup.** Delete a file? OneDrive deletes it everywhere. Ransomware encrypts your Documents folder? OneDrive happily syncs the encrypted files to the cloud. Microsoft's "version history" helps with individual files but won't save you from a real disaster.

OneDrive is fine for sharing documents. It is not a backup strategy for your OpenClaw installation.

## WSL vs Native: Pick One

You have two paths on Windows:

| Approach | Pros | Cons |
|----------|------|------|
| **Native (PowerShell)** | No extra layer, Task Scheduler, robocopy built-in | Different tools than Linux/Mac guides |
| **WSL** | Same Borg/restic tools as Linux | Extra complexity, filesystem bridge overhead |

**Our recommendation: Go native.** The scripts in this guide use PowerShell and built-in Windows tools. They're tested, they work, and you don't need to debug WSL filesystem permissions at 2 AM during a restore.

If you're already a WSL power user, the [Linux Local guide](linux-local.md) works inside WSL with minor path adjustments. But for backups specifically, native Windows tools are more reliable.

## What to Backup

| Item | Default Path | Priority |
|------|-------------|----------|
| OpenClaw home | `%USERPROFILE%\.openclaw\` | 🔴 Critical |
| Workspace | `%USERPROFILE%\hub-local\` | 🔴 Critical |
| SQLite databases | Inside `.openclaw\` | 🔴 Critical |
| Environment/credentials | `.env` files, API keys | 🔴 Critical |
| Custom scripts | Various | 🟡 Important |
| Installed packages | `winget list` | 🟢 Nice to have |
| Scheduled tasks | `\OpenClaw\` task folder | 🟢 Nice to have |

## Prerequisites

```powershell
# Install Node.js (if not already installed)
winget install OpenJS.NodeJS.LTS

# Install Git
winget install Git.Git

# Verify
node --version
git --version

# robocopy is built into Windows — no install needed
robocopy /?
```

## One-Command Setup

```powershell
# Run as Administrator
cd \path\to\openclaw-backup-guide
.\scripts\windows\setup-taskscheduler.ps1
```

This creates all the scheduled tasks. See `scripts/windows/setup-taskscheduler.ps1` for exactly what it does — it creates tasks under the `\OpenClaw\` folder in Task Scheduler.

## Tier 1: Git Backup (Hourly)

Same concept as every other platform — safely snapshot databases, commit, push.

### Setup

```powershell
# Make sure your workspace is a git repo
cd ~\hub-local
git init  # skip if already a repo
git remote add origin git@github.com:YOUR_USERNAME/YOUR_REPO.git

# Configure
cd \path\to\openclaw-backup-guide
Copy-Item .env.example .env
notepad .env  # edit paths

# Test it
.\scripts\windows\backup-git.ps1
```

### What `backup-git.ps1` Does

1. Loads config from `.env` (with a custom PowerShell env loader — no `source` on Windows)
2. Runs `backup-db.js` via Node.js for safe SQLite snapshots
3. `git add -A`, commit with timestamp and hostname, push to remote

### Automate with Task Scheduler

The setup script creates a task that runs every hour. To do it manually:

```powershell
# Create an hourly trigger
$trigger = New-ScheduledTaskTrigger -Once -At "00:00" `
    -RepetitionInterval (New-TimeSpan -Hours 1) `
    -RepetitionDuration (New-TimeSpan -Days 365)

# Create the action
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$HOME\openclaw-backup-guide\scripts\windows\backup-git.ps1`""

# Register it
Register-ScheduledTask `
    -TaskName "Backup-Git" `
    -TaskPath "\OpenClaw\" `
    -Action $action `
    -Trigger $trigger `
    -Description "OpenClaw Tier 1: Git commit and push (hourly)"
```

Or just run `setup-taskscheduler.ps1` and it handles all of this.

### Task Scheduler Tips

```powershell
# List all OpenClaw tasks
Get-ScheduledTask -TaskPath "\OpenClaw\"

# Run a task right now
Start-ScheduledTask -TaskPath "\OpenClaw\" -TaskName "Backup-Git"

# Check last run result
Get-ScheduledTask -TaskPath "\OpenClaw\" | Get-ScheduledTaskInfo

# Remove all OpenClaw tasks
Get-ScheduledTask -TaskPath "\OpenClaw\" | Unregister-ScheduledTask -Confirm:$false
```

**Important:** Task Scheduler settings in our scripts include `AllowStartIfOnBatteries` and `StartWhenAvailable` — your laptop won't skip backups just because it's unplugged or was asleep.

## Tier 2: Robocopy (3x Daily)

Robocopy (Robust File Copy) is built into Windows and has been since Vista. It's not as sophisticated as Borg or restic (no deduplication, no encryption), but it's reliable, fast, and zero-install.

### What `backup-robocopy.ps1` Does

1. Safe SQLite snapshot via `backup-db.js`
2. Robocopy mirrors `~\.openclaw\` to `~\backups\openclaw\openclaw-home\`
3. Robocopy mirrors `~\hub-local\` to `~\backups\openclaw\workspace\`
4. Creates a timestamped `.zip` snapshot in `~\backups\openclaw\snapshots\`
5. Prunes old snapshots (keeps last 7)

Excludes: `node_modules`, `.git`, `__pycache__`, `*.log`, `*.tmp`

### Run It

```powershell
.\scripts\windows\backup-robocopy.ps1
```

### Robocopy Flags Explained

The script uses `/MIR` (mirror — exact copy, deletes extras at destination), `/MT:4` (4 threads), and `/NFL /NDL /NP` (reduce log noise). Exit codes 0-7 mean success (yes, really — robocopy is weird like that).

### Want Encryption?

Robocopy doesn't encrypt. Two options:

1. **BitLocker** the backup drive — System Settings → BitLocker → Turn On. The whole drive is encrypted at rest.
2. **Install restic** via `scoop install restic` or `choco install restic` and use it instead. Same approach as the [macOS guide](macos.md).

### Automate It

The setup script creates three tasks — morning (8 AM), afternoon (2 PM), night (10 PM):

```powershell
.\scripts\windows\setup-taskscheduler.ps1
```

## Tier 3: Veeam Agent (System Image)

[Veeam Agent for Windows](https://www.veeam.com/windows-endpoint-server-backup-free.html) is free for personal use and creates full system images with bare-metal recovery. It's the best free option for Windows system backups, period.

### Setup (One-Time, GUI)

1. **Download** Veeam Agent FREE from [veeam.com](https://www.veeam.com/windows-endpoint-server-backup-free.html)
2. **Install** — no license key needed for the free edition
3. **Configure a backup job:**
   - Type: **Entire Computer** (bare-metal capable)
   - Destination: External USB drive or network share
   - Schedule: Monthly (or before major Windows updates)
4. **Create Recovery Media** — Veeam can create a bootable USB. **Do this.** You'll need it if your disk dies.

### Trigger via Script

Once configured in the GUI, our script can trigger it:

```powershell
.\scripts\windows\backup-veeam.ps1
```

`backup-veeam.ps1` finds the Veeam scheduled task, checks if it's already running, and triggers it if not. First backup is full (takes hours). Subsequent ones are incremental and fast.

### Why Veeam Over Windows Backup?

Windows has a built-in "Backup and Restore (Windows 7)" tool. It technically works. It's also been deprecated, poorly maintained, and has reliability issues. Veeam is what the pros use, and the free version is genuinely excellent.

## Tier 4: Offsite

Get your backups off the machine:

1. **GitHub** — Tier 1 git pushes (free, automatic)
2. **External USB drive** — Keep a second backup drive at a different location. Swap monthly.
3. **Cloud sync** — Use rclone to push robocopy snapshots to Backblaze B2 or S3:
   ```powershell
   # Install rclone
   winget install Rclone.Rclone
   
   # Sync snapshots to B2
   rclone sync ~\backups\openclaw\snapshots b2:your-bucket/openclaw-snapshots
   ```
4. **NAS** — If you have a Synology, map it as a network drive and point robocopy at it.

See [offsite.md](offsite.md) for the full strategy.

## Monitoring

### Check backup logs

```powershell
# Logs live in ~\logs\openclaw-backup\
Get-Content ~\logs\openclaw-backup\git.log -Tail 20
Get-Content ~\logs\openclaw-backup\robocopy.log -Tail 20
```

### Quick health check

```powershell
# Last git backup
cd ~\hub-local; git log --oneline -5

# Task Scheduler status
Get-ScheduledTask -TaskPath "\OpenClaw\" | 
    Select TaskName, State | Format-Table

# Last run info
Get-ScheduledTask -TaskPath "\OpenClaw\" | 
    Get-ScheduledTaskInfo | 
    Select TaskName, LastRunTime, LastTaskResult | Format-Table

# Backup sizes
Get-ChildItem ~\backups\openclaw\snapshots\ | 
    Sort LastWriteTime -Descending | 
    Select Name, @{N='Size(MB)';E={[math]::Round($_.Length/1MB,1)}} -First 5
```

### Verification

```powershell
# If you have WSL:
wsl bash -c "./scripts/common/verify-backup.sh"

# Without WSL, manual checks:
# 1. Git is current?
cd ~\hub-local; git status

# 2. Recent snapshots exist?
Get-ChildItem ~\backups\openclaw\snapshots\ | Sort LastWriteTime -Descending | Select -First 3

# 3. Veeam last backup?
# Check in Veeam Agent tray icon or Windows Event Viewer
```

## Complete Setup (TL;DR)

```powershell
# 1. Clone this repo
git clone https://github.com/your-org/openclaw-backup-guide.git ~\openclaw-backup-guide

# 2. Configure
cd ~\openclaw-backup-guide
Copy-Item .env.example .env
notepad .env  # set OPENCLAW_HOME, OPENCLAW_WORKSPACE

# 3. Install tasks (Run as Administrator)
.\scripts\windows\setup-taskscheduler.ps1

# 4. Install Veeam Agent (manual — download from veeam.com)
# Configure via GUI: Entire Computer → External Drive → Monthly

# 5. Run initial backup
.\scripts\windows\backup-git.ps1
.\scripts\windows\backup-robocopy.ps1

# 6. Verify
Get-ScheduledTask -TaskPath "\OpenClaw\" | Format-Table TaskName, State
```

---

*Next: [Restore Guide](restore.md) — read it before you need it.*
