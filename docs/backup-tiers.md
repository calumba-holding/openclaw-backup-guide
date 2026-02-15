# The 4-Tier Backup Philosophy

## Why Four Tiers?

Because no single backup method protects against everything. Each tier covers a different failure mode:

| Failure | Tier 1 (Git) | Tier 2 (Files) | Tier 3 (Image) | Tier 4 (Offsite) |
|---------|:---:|:---:|:---:|:---:|
| Accidental config change | ✅ | ✅ | ✅ | ✅ |
| Deleted a file | ✅ | ✅ | ✅ | ✅ |
| Corrupted database | ✅ | ✅ | ✅ | ✅ |
| Bad OS update | ❌ | ❌ | ✅ | ✅ |
| Disk failure | ❌ | ❌ | ✅ | ✅ |
| Ransomware | ❌ | ❌ | ❌ | ✅ |
| Fire / theft / flood | ❌ | ❌ | ❌ | ✅ |
| Datacenter goes down (VPS) | ❌ | ❌ | ❌ | ✅ |

## Tier 1: Git (Hourly)

**What:** Snapshot your OpenClaw databases (safely, using SQLite's `.backup()` API), then commit everything to git and push to a remote.

**Why:** This is your "oops" button. Accidentally broke your config? `git log` and restore. Database got corrupted by a bad migration? Check out yesterday's snapshot. It's fast, it's versioned, and GitHub/GitLab gives you free offsite storage.

**How often:** Every hour via cron.

**What it costs:** Free (GitHub/GitLab private repos are free).

**What it doesn't protect against:** Anything that destroys your git remote (GitHub goes down) or anything at the OS level (bad kernel update, disk failure). Also, git isn't great for large binary files — keep your DB snapshots reasonable.

**Recovery time:** Minutes. `git checkout` or `git revert`.

## Tier 2: File-Level (3x Daily)

**What:** Deduplicated, encrypted, incremental backups of your entire OpenClaw directory tree. We use [Borg](https://www.borgbackup.org/) on Linux and [restic](https://restic.net/) on macOS.

**Why:** Deduplication means storing 30 days of backups takes barely more space than one copy. Encryption means you can store them anywhere without worrying. Incremental means each backup is fast — only changed blocks get stored.

**How often:** 3x daily (8am, 2pm, 10pm works well).

**What it costs:** Disk space for the repository (typically 2-5x your OpenClaw directory size for a month of history).

**Prune policy:** We keep 7 daily, 4 weekly, 3 monthly. Old backups get pruned automatically. Adjust to taste.

**Recovery time:** ~30 minutes. Mount the backup, copy files out.

## Tier 3: System Image (Monthly)

**What:** A full disk image that captures everything — OS, packages, configs, OpenClaw, the works. We use [fsarchiver](https://www.fsarchiver.org/) on Linux, Time Machine on macOS, and Veeam Agent (free) on Windows.

**Why:** If your disk dies or your OS gets corrupted, you can restore to bare metal. No reinstalling packages, no reconfiguring services, no "wait, what version of Node was I running?"

**How often:** Monthly, or before major OS upgrades.

**What it costs:** One full disk image per month. Typically 10-50GB compressed depending on your disk usage.

**Recovery time:** 1-2 hours, depending on disk speed and image size.

**Note for VPS users:** You can't easily do this on a VPS. Use your provider's snapshot feature as a supplement, but don't rely on it — they can lose snapshots too. Your real protection is Tier 4.

## Tier 4: Offsite (Continuous)

**What:** Get copies of your backups physically away from your machine. This means a NAS on your local network, an external drive, cloud storage (S3, Backblaze B2, Google Drive), or ideally a combination.

**Why:** If your house floods, your machine and your local backups are both gone. If ransomware hits, anything mounted or accessible gets encrypted. Offsite backups are your nuclear option — the thing that saves you when everything local is toast.

**How:** We use a Synology NAS with Cloud Sync to Google Drive. This gives us:
1. **Local copy** — on the OpenClaw machine
2. **GitHub** — Tier 1 git pushes
3. **NAS** — local network, different physical device
4. **Cloud** — Google Drive via NAS Cloud Sync

Four copies. Different locations. Different failure domains.

**What it costs:** NAS hardware ($200-500), or cloud storage ($5-10/month for Backblaze B2 or rsync.net).

## What If I Only Do One?

**Do Tier 1.** Seriously. Five minutes of setup gives you hourly snapshots with version history pushed to GitHub. That alone handles 90% of "oh shit" moments.

Then add tiers as your paranoia grows:

| Your Paranoia Level | Do This |
|---|---|
| "I should probably back up" | Tier 1 |
| "I've lost data before" | Tier 1 + 2 |
| "My livelihood depends on this" | Tier 1 + 2 + 3 |
| "I've seen things" | All four tiers |

## The 3-2-1 Rule

The classic backup rule: **3 copies, 2 different media types, 1 offsite.** Our 4-tier approach exceeds this:

- **3+ copies:** Local files, git remote, Borg/restic repo, NAS, cloud
- **2+ media:** SSD, NAS HDDs, cloud object storage
- **1+ offsite:** GitHub, cloud storage, physically separate NAS

---

*Next: Pick your platform guide — [Linux Local](linux-local.md) · [Linux VPS](linux-vps.md) · [macOS](macos.md) · [Windows](windows.md)*
