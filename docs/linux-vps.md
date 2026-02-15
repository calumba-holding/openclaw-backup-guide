# Linux VPS Guide

Running OpenClaw on a VPS (Hetzner, DigitalOcean, Hostinger, Linode, Vultr, etc.)? This guide covers the unique challenges of backing up a remote machine you can't physically touch.

## VPS-Specific Challenges

- **No physical access.** If the disk dies, you can't plug in a USB drive.
- **Provider snapshots are supplementary, not primary.** They can vanish if you close your account, miss a payment, or the provider has an outage.
- **Bandwidth costs money.** Large offsite backups can get expensive.
- **Shared infrastructure.** Your "disk" is probably a network volume managed by the provider.
- **No bare-metal restore.** You restore by provisioning a new VPS and rebuilding.

## What to Backup

Same as any Linux box, but with extra emphasis on getting data **off the VPS**:

| Item | Path | Priority |
|------|------|----------|
| OpenClaw home | `~/.openclaw/` | 🔴 Critical |
| Workspace | `~/hub-local/` | 🔴 Critical |
| SQLite databases | Inside `~/.openclaw/` | 🔴 Critical |
| Environment/credentials | `.env`, API keys | 🔴 Critical |
| Server config | nginx, systemd units, etc. | 🟡 Important |
| Package list | `dpkg --get-selections` | 🟢 Nice to have |

## Tier 1: Git Backup (Hourly)

Identical to local Linux. This is your most important tier on a VPS because it gets data off the machine every hour.

```bash
# Setup (same as local)
cd ~/hub-local
git init
git remote add origin git@github.com:YOUR_USERNAME/YOUR_REPO.git

# Install cron
(crontab -l 2>/dev/null; echo "0 * * * * cd ~/hub-local && ~/openclaw-backup-guide/scripts/linux/backup-git.sh >> ~/logs/openclaw-backup/git.log 2>&1") | crontab -
```

**VPS tip:** Use SSH deploy keys (read/write) instead of your personal SSH key. If the VPS is compromised, you can revoke just the deploy key.

## Tier 2: Borg Backup to Remote Storage

On a VPS, local Borg backups don't help much (same disk, same failure domain). Send Borg backups directly to a remote destination.

### Option A: Backblaze B2 via rclone (~$5/TB/month)

```bash
# Install rclone
curl https://rclone.org/install.sh | sudo bash

# Configure B2
rclone config
# Choose: New remote → Backblaze B2 → Enter account ID and app key

# Use rclone as a Borg remote (via rclone serve)
# Or: Borg to local, then rclone sync to B2
./scripts/linux/backup-borg.sh

# Sync Borg repo to B2
rclone sync ~/backups/borg/openclaw b2:your-bucket/borg-openclaw --transfers 4
```

### Option B: rsync.net (~$0.02/GB/month)

rsync.net gives you a remote filesystem with SSH access — Borg can use it directly.

```bash
# Point Borg at rsync.net
export BORG_REPO="ssh://de1234@de1234.rsync.net/./openclaw"
borg init --encryption=repokey "$BORG_REPO"

# Then just run backup-borg.sh as normal
./scripts/linux/backup-borg.sh
```

### Option C: Another VPS / Home Server via SSH

```bash
export BORG_REPO="ssh://backup@your-backup-server.com/~/borg/openclaw"
borg init --encryption=repokey "$BORG_REPO"
```

## Tier 3: Provider Snapshots (Supplementary)

Every major VPS provider offers snapshots. Use them, but don't rely on them alone.

### Hetzner
```bash
# Via CLI (hcloud)
hcloud server create-image --type snapshot --description "openclaw-$(date +%Y-%m-%d)" YOUR_SERVER_ID
# Or schedule via API
```

### DigitalOcean
```bash
# Enable automated backups in the Droplet settings ($1/month)
# Or via CLI:
doctl compute droplet-action snapshot YOUR_DROPLET_ID --snapshot-name "openclaw-$(date +%Y-%m-%d)"
```

### Vultr / Linode
Similar snapshot APIs available. Check your provider's docs.

**Important limitations:**
- Snapshots are stored by the provider, on the provider's infrastructure
- If you cancel your account, snapshots are deleted
- If the provider has a catastrophic failure, snapshots may be lost
- Snapshot restore usually means a new VPS with a new IP

## Tier 4: Get Data Off the VPS

This is the most critical tier for VPS users. Your VPS is rented infrastructure — treat it as ephemeral.

### Minimum Viable Offsite
```bash
# Daily tarball to a different location
tar czf /tmp/openclaw-backup.tar.gz \
  --exclude='node_modules' \
  --exclude='.git' \
  ~/.openclaw ~/hub-local ~/backups/openclaw/db

# Upload to B2
rclone copy /tmp/openclaw-backup.tar.gz b2:your-bucket/openclaw-daily/
rm /tmp/openclaw-backup.tar.gz
```

### Belt and Suspenders
1. **Git push** (Tier 1) — data on GitHub every hour
2. **Borg to rsync.net** — encrypted incrementals to cheap remote storage
3. **Provider snapshots** — monthly, as a convenience
4. **Daily tarball to B2** — cheap insurance

## VPS → Local Migration Guide

We actually migrated from a VPS to a local Linux Mint box. Here's how:

### 1. Get everything off the VPS
```bash
# On your local machine:
rsync -avz --progress user@your-vps.com:~/.openclaw/ ~/.openclaw/
rsync -avz --progress user@your-vps.com:~/hub-local/ ~/hub-local/
rsync -avz --progress user@your-vps.com:~/backups/ ~/backups/
```

### 2. Install OpenClaw locally
Follow the standard OpenClaw installation guide for your OS.

### 3. Restore databases
```bash
# Stop the fresh installation
openclaw gateway stop

# Copy backed-up databases over the fresh ones
node scripts/common/restore-db.js

# Start it up
openclaw gateway start
```

### 4. Verify
```bash
# Check that everything's working
openclaw gateway status
```

### 5. Update DNS / tunnels
If you were using a domain or tunnel to reach the VPS, update it to point to your local machine (or set up a new tunnel like Cloudflare Tunnel).

## Monitoring on a VPS

Since you can't see the machine, monitoring is extra important:

```bash
# Simple cron-based monitoring
# Send a "heartbeat" to a monitoring service every hour
0 * * * * curl -fsS -m 10 --retry 3 https://hc-ping.com/YOUR-UUID > /dev/null

# Or use the verify script with email notification
0 6 * * 0 ~/openclaw-backup-guide/scripts/common/verify-backup.sh || echo "Backup verification failed" | mail -s "⚠️ OpenClaw Backup Alert" you@example.com
```

Free monitoring services:
- [Healthchecks.io](https://healthchecks.io/) — free tier, monitors cron jobs
- [UptimeRobot](https://uptimerobot.com/) — free tier, monitors endpoints
- [Cronitor](https://cronitor.io/) — free tier for a few monitors

## Cost Comparison

| Service | Storage | Cost/Month | Notes |
|---------|---------|-----------|-------|
| GitHub (private repo) | ~1-2 GB | Free | Tier 1 git |
| Backblaze B2 | Per GB | ~$5/TB | First 10GB free |
| rsync.net | Per GB | ~$0.02/GB | SSH access, Borg-friendly |
| Hetzner Storage Box | 1TB+ | €3.81/month | BorgBackup over SSH |
| Provider snapshots | Varies | $0-5/month | Usually free or cheap |

---

*Next: [Restore Guide](restore.md) — especially important for VPS users.*
