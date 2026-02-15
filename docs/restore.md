# How to Restore

**This is the most important document in the entire repository.**

A backup you can't restore is not a backup. It's a feelings journal. "I feel safe because I have backups" means nothing if you've never tested a restore and don't know how to do one under pressure.

Read this page now, while your machine is working and you're not panicking. Bookmark it. Print it if you're the printing type. Future-you will be grateful.

---

## The Golden Rule: OpenClaw First, Then Data

When your machine dies, your instinct will be to restore everything at once. Resist that urge. Here's the priority order:

1. **Get a working OS** (install fresh or restore system image)
2. **Install OpenClaw** (fresh install — it's fast)
3. **Restore your OpenClaw databases** (chat history, memory, state)
4. **Restore your workspace** (configs, scripts, projects)
5. **Restore everything else** (nice-to-haves, customizations)

Why this order? Because OpenClaw running with yesterday's data is infinitely better than spending 6 hours trying to do a perfect bare-metal restore. Get it working, then make it perfect.

---

## Quick Reference: What to Restore from Where

| What You Lost | Restore From | Time |
|---------------|-------------|------|
| A config file you just broke | **Tier 1: Git** — `git checkout` or `git revert` | 2 minutes |
| A file you deleted yesterday | **Tier 2: Borg/restic** — extract from snapshot | 10 minutes |
| Your whole OpenClaw setup | **Tier 1: Git clone** + **Tier 2: restore DBs** | 30 minutes |
| Your OS is toast | **Tier 3: System image** or fresh install + Tier 1/2 | 1-2 hours |
| Your machine is gone (fire/theft) | **Tier 4: Offsite** — clone from GitHub + restore from B2 | 2-4 hours |

---

## Tier 1 Restore: Git

The easiest restore. You broke something, you want to go back.

### "I broke a config file"

```bash
# See what changed
cd ~/hub-local
git diff

# Revert a specific file to last commit
git checkout -- path/to/file

# Revert everything to last commit
git checkout -- .
```

### "I need yesterday's version"

```bash
# Find the commit you want
git log --oneline -20

# Check out a file from a specific commit
git checkout abc1234 -- path/to/file

# Or restore a database snapshot
git checkout abc1234 -- backups/db/
```

### "I need to restore from GitHub on a new machine"

```bash
# Clone your workspace
git clone git@github.com:YOUR_USERNAME/YOUR_REPO.git ~/hub-local
cd ~/hub-local

# Your DB snapshots are in the repo
ls backups/db/

# Restore them (see Database Restore below)
```

---

## Tier 2 Restore: Borg / restic

### restic (macOS, or Linux if you chose restic)

```bash
# List available snapshots
restic -r ~/backups/restic/openclaw snapshots

# Restore everything from the latest snapshot
restic -r ~/backups/restic/openclaw restore latest --target /tmp/restore

# Restore a specific path
restic -r ~/backups/restic/openclaw restore latest \
  --target /tmp/restore \
  --include "/.openclaw/"

# Restore from a specific snapshot (not latest)
restic -r ~/backups/restic/openclaw restore abc1234 --target /tmp/restore

# Then copy files where they belong
cp -r /tmp/restore/.openclaw/ ~/.openclaw/
cp -r /tmp/restore/hub-local/ ~/hub-local/
```

**From a remote restic repo (B2, S3, SFTP):**

```bash
# Same commands, different repo path
export RESTIC_REPOSITORY="b2:your-bucket:openclaw"
export B2_ACCOUNT_ID="your-id"
export B2_ACCOUNT_KEY="your-key"
export RESTIC_PASSWORD="your-password"

restic snapshots
restic restore latest --target /tmp/restore
```

### Borg (Linux)

```bash
# List available archives
borg list ~/backups/borg/openclaw

# Mount and browse (pick what you need)
mkdir /tmp/borg-mount
borg mount ~/backups/borg/openclaw::archive-name /tmp/borg-mount
ls /tmp/borg-mount
# Copy what you need, then:
borg umount /tmp/borg-mount

# Or extract everything
cd /
borg extract ~/backups/borg/openclaw::archive-name

# Extract a specific path
borg extract ~/backups/borg/openclaw::archive-name home/user/.openclaw/
```

**From a remote Borg repo:**

```bash
export BORG_REPO="ssh://de1234@de1234.rsync.net/./openclaw"
export BORG_PASSPHRASE="your-passphrase"

borg list
borg extract ::archive-name
```

---

## Database Restore (Critical)

SQLite databases are the heart of OpenClaw — chat history, memory, state. Our backup scripts use SQLite's `.backup()` API to create safe snapshots. Here's how to restore them.

### Using the Restore Script

```bash
# Stop OpenClaw first!
openclaw gateway stop

# Restore databases from backup
node scripts/common/restore-db.js

# Restart
openclaw gateway start

# Verify
openclaw gateway status
```

### Manual Database Restore

If the script doesn't work (or you want to do it by hand):

```bash
# Stop OpenClaw
openclaw gateway stop

# Find your DB snapshots
ls ~/backups/openclaw/db/
# or from git:
ls ~/hub-local/backups/db/

# Copy them over the live databases
# (The exact filenames depend on your OpenClaw version)
cp ~/backups/openclaw/db/*.db ~/.openclaw/

# Verify the database isn't corrupted
sqlite3 ~/.openclaw/your-database.db "PRAGMA integrity_check;"
# Should output: "ok"

# Restart
openclaw gateway start
```

### ⚠️ Database Gotchas

- **Always stop OpenClaw before restoring databases.** Overwriting a SQLite file while the process is using it = corruption.
- **Check integrity after restore.** Run `PRAGMA integrity_check;` on every restored database.
- **WAL files matter.** If you see `.db-wal` or `.db-shm` files next to a database, they contain uncommitted data. If you're restoring from a raw file copy (not our backup script), you might lose recent writes. Our `backup-db.js` script handles this correctly.

---

## Tier 3 Restore: System Image

### Linux (fsarchiver)

```bash
# 1. Boot from a live USB (Ubuntu, Mint, etc.)

# 2. Mount the drive containing your image
mount /dev/sdb1 /mnt  # adjust for your setup

# 3. Check the image
fsarchiver archinfo /mnt/backups/images/myhostname-2025-01-15.fsa

# 4. Restore to your partition
fsarchiver restfs /mnt/backups/images/myhostname-2025-01-15.fsa id=0,dest=/dev/nvme0n1p2

# 5. Fix the bootloader
mount /dev/nvme0n1p2 /target
mount --bind /dev /target/dev
mount --bind /proc /target/proc
mount --bind /sys /target/sys
chroot /target
grub-install /dev/nvme0n1
update-grub
exit
umount -R /target

# 6. Reboot and pray (just kidding — this works reliably)
reboot
```

### macOS (Time Machine)

1. **Boot into Recovery:** Hold `⌘R` (Intel) or hold Power button (Apple Silicon) during startup
2. **Select "Restore from Time Machine Backup"**
3. **Pick the backup date** — choose the most recent one that predates your issue
4. **Wait** — this takes 1-3 hours depending on disk size
5. **Reboot** — everything is exactly as it was

That's it. Time Machine restore is one of the few things Apple gets genuinely right.

### Windows (Veeam Agent)

1. **Boot from Veeam Recovery Media** (you created this earlier, right? RIGHT?)
2. **Select "Bare Metal Recovery"**
3. **Choose the backup** — point it at your external drive or network share
4. **Select "Entire Computer"**
5. **Wait** — 1-3 hours
6. **Reboot**

If you didn't create recovery media:
1. Download Veeam Recovery Media ISO from another computer
2. Write it to a USB drive with Rufus
3. Boot from it
4. Proceed as above

---

## 🚨 "My Machine Died, Now What?" — Emergency Walkthrough

Your machine is gone. Dead SSD, stolen laptop, house fire, doesn't matter. Here's exactly what to do, step by step.

### Step 0: Don't Panic

You have backups. You followed this guide. Take a breath.

### Step 1: Get a Machine (30 minutes)

Any computer will do temporarily. Borrow one, buy one, spin up a VPS. OpenClaw runs on basically anything.

### Step 2: Install the OS (30-60 minutes)

Fresh install of whatever OS you're going to use. Don't overthink it.

- **Linux:** Download Ubuntu/Mint ISO, flash to USB, install
- **macOS:** If you have a Mac, it comes with an OS. Time Machine restore gets you the whole system back.
- **Windows:** Download Windows ISO from Microsoft, install, activate later

### Step 3: Install OpenClaw (10 minutes)

```bash
# Follow the standard OpenClaw installation guide for your OS
# This gets you a working but empty OpenClaw
```

### Step 4: Restore from Git (5 minutes)

```bash
# Clone your workspace — this has your configs and DB snapshots
git clone git@github.com:YOUR_USERNAME/YOUR_REPO.git ~/hub-local
```

If you can't access GitHub (lost SSH key):
- Use HTTPS clone with your GitHub password/token
- Or restore from your Tier 4 offsite backup (B2, rsync.net, NAS)

### Step 5: Restore Databases (10 minutes)

```bash
# Stop the fresh OpenClaw
openclaw gateway stop

# Restore databases from git snapshots
node ~/hub-local/scripts/common/restore-db.js
# or manually:
cp ~/hub-local/backups/db/*.db ~/.openclaw/

# Start OpenClaw
openclaw gateway start

# Verify
openclaw gateway status
```

### Step 6: Restore from Tier 2 (if you need more) (20 minutes)

Git only has hourly snapshots. If you need files between snapshots, or files that weren't in git:

```bash
# restic from B2
export RESTIC_REPOSITORY="b2:your-bucket:openclaw"
export B2_ACCOUNT_ID="your-id"
export B2_ACCOUNT_KEY="your-key"
export RESTIC_PASSWORD="your-password"

restic restore latest --target /tmp/restore
cp -r /tmp/restore/.openclaw/ ~/.openclaw/
cp -r /tmp/restore/hub-local/ ~/hub-local/

# Borg from rsync.net
export BORG_REPO="ssh://de1234@de1234.rsync.net/./openclaw"
export BORG_PASSPHRASE="your-passphrase"
cd /
borg extract ::latest
```

### Step 7: Verify Everything Works

```bash
openclaw gateway status
# Chat with your agent — is the memory intact?
# Check recent chat history — is it there?
```

### Step 8: Set Up Backups on the New Machine

Don't forget to set up backups again on the new machine. Follow the setup guide for your OS.

**Total time from dead machine to working OpenClaw: ~1-2 hours** (assuming you have a new machine ready).

---

## Test Your Restores (Quarterly)

**A backup you've never tested is a backup that might not work.** Schedule this quarterly.

### The Quarterly Restore Test

Set a calendar reminder for every 3 months. Here's what to do:

#### Quick Test (15 minutes)

```bash
# 1. Can you list Borg/restic snapshots?
borg list ~/backups/borg/openclaw  # or
restic -r ~/backups/restic/openclaw snapshots

# 2. Can you extract a file?
restic -r ~/backups/restic/openclaw restore latest --target /tmp/test-restore --include "/.openclaw/"
# or
borg extract ~/backups/borg/openclaw::latest-archive home/user/.openclaw/ --target /tmp/test-restore

# 3. Is the database valid?
sqlite3 /tmp/test-restore/.openclaw/*.db "PRAGMA integrity_check;"
# Should output: "ok"

# 4. Can you access offsite backups?
restic -r b2:your-bucket:openclaw snapshots  # or whatever your offsite is

# 5. Clean up
rm -rf /tmp/test-restore
```

#### Full Test (1 hour, once a year)

Do a complete restore to a temporary directory or VM:

1. Create a VM or use a spare machine
2. Install OpenClaw fresh
3. Restore everything from your backups as if the main machine died
4. Verify OpenClaw starts and has your data
5. Destroy the test environment

If any step fails, **fix it now.** Not "later." Not "next quarter." Now.

### Restore Test Checklist

```
□ Borg/restic can list snapshots
□ Borg/restic can extract files
□ Extracted databases pass integrity check
□ Offsite backups are accessible
□ Git clone works from remote
□ restore-db.js runs successfully
□ OpenClaw starts after restore
□ Chat history is present
□ Borg/restic password is in password manager (not just on the backed-up machine)
□ Borg key file is saved somewhere other than the backup itself
```

---

## Common Gotchas & Troubleshooting

### "I forgot my Borg/restic password"

Game over. Encrypted backups without the password are unrecoverable. This is by design.

**Prevention:** Store the password in your password manager (1Password, Bitwarden, etc.). Store it in a second location too — printed in a safe, in a sealed envelope with a trusted person, wherever. Just not only on the machine being backed up.

### "Borg key not found"

Borg uses a key stored in `~/.config/borg/keys/`. If you lose this AND the passphrase, the backup is unrecoverable.

**Prevention:** Run `borg key export` and save the key file somewhere safe (password manager, USB in a safe, etc.). Our setup scripts remind you to do this.

### "SQLite database is corrupted after restore"

Usually means:
1. The backup was taken while OpenClaw was writing to the database (raw file copy, not our backup script)
2. WAL files weren't included in the backup

**Fix:** Try an older snapshot. If using our `backup-db.js` script, this shouldn't happen — it uses SQLite's `.backup()` API which creates a consistent snapshot.

```bash
# Check integrity
sqlite3 your-database.db "PRAGMA integrity_check;"

# If corrupted, try recovering what you can
sqlite3 your-database.db ".recover" | sqlite3 recovered.db
```

### "Git push failed during backup — data lost?"

No. The commit is local. The data is in your local git history even if the push failed. Fix the push issue and push again.

```bash
cd ~/hub-local
git log --oneline -5  # your commits are here
git push origin main  # try again
```

### "restic/Borg backup is huge — my disk is full"

Prune old snapshots:

```bash
# restic
restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 3 -r ~/backups/restic/openclaw

# Borg
borg prune --keep-daily=7 --keep-weekly=4 --keep-monthly=3 ~/backups/borg/openclaw
```

Also check that you're excluding `node_modules`, `.git`, and other large transient directories.

### "Time Machine says 'backup disk not available'"

The drive was unplugged, ejected, or died. Plug it back in, or replace it. Time Machine will resume automatically.

### "Veeam recovery media doesn't boot"

1. Check BIOS/UEFI boot order — USB should be first
2. Try both UEFI and Legacy boot modes
3. Recreate the recovery media on a different USB drive
4. Make sure Secure Boot is disabled (or use the UEFI version)

### "I'm restoring on different hardware"

- **Linux:** Usually works. You might need to update GRUB and regenerate initramfs.
- **macOS:** Apple Migration Assistant handles hardware differences well. Time Machine restore on different Mac models generally works.
- **Windows:** Veeam handles hardware changes. Windows might need to reactivate. Driver differences are usually auto-resolved.

---

## Key Passwords & Access You Need to Save

Store all of these **outside** the machine being backed up:

| Secret | Where to Store |
|--------|---------------|
| Borg/restic password | Password manager + printed copy |
| Borg key file | Password manager + USB in safe |
| GitHub SSH key (or token) | Password manager |
| B2/S3 access keys | Password manager |
| rsync.net credentials | Password manager |
| NAS admin password | Password manager |
| OS login password | Password manager |
| Encryption passphrase (age/GPG) | Password manager + printed copy |

If your password manager is only on the machine being backed up, you have a chicken-and-egg problem. Use a cloud-synced password manager (1Password, Bitwarden) or keep a physical backup of critical credentials.

---

*You made it. Now go test a restore. Seriously. Right now. Open a terminal and verify you can list your snapshots and extract a file. It takes 5 minutes and you'll sleep better tonight.*
