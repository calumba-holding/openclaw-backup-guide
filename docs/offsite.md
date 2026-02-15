# Offsite & Cloud Backup Strategies

All your backups are on the same machine. Your house floods. Now you have zero backups.

This is the document about making sure that doesn't happen.

## Why Offsite Matters

Local backups protect against:
- ✅ Accidental deletion
- ✅ Corrupted files
- ✅ Bad updates
- ❌ House fire
- ❌ Theft
- ❌ Ransomware (if the backup drive is mounted/accessible)
- ❌ Power surge that fries everything on your desk

Offsite backups protect against all of the above. That's the entire argument. Moving on.

## The 3-2-1 Rule

The classic, the one that actually matters:

- **3** copies of your data
- **2** different storage media (SSD + cloud, NAS HDDs + git remote, etc.)
- **1** copy offsite (physically separate location)

Our 4-tier system exceeds 3-2-1:

| Copy | Where | Media | Offsite? |
|------|-------|-------|----------|
| Live data | Your machine's SSD | SSD | ❌ |
| Git remote | GitHub/GitLab | Cloud object storage | ✅ |
| Borg/restic repo | Local backup dir (or NAS) | HDD/SSD | ❌ (or ✅ if NAS) |
| Cloud backup | B2/S3/Google Drive | Cloud object storage | ✅ |
| NAS | Synology on your network | HDD (RAID) | Kinda (different device, same building) |

A NAS in the same house is **not truly offsite** — but it's a different failure domain from your main machine. It survives your SSD dying. It doesn't survive your house flooding.

## Encryption Before Upload (Always)

**Rule: Never upload unencrypted backups to any cloud service.** Period.

- Borg encrypts by default (`--encryption=repokey`)
- restic encrypts by default (always, no opt-out)
- Git repos on GitHub are "private" but GitHub can read them. For truly sensitive data, use [git-crypt](https://github.com/AGWA/git-crypt) or don't put it in git.
- Tarballs/zip files: encrypt with `gpg` or `age` before uploading

```bash
# Encrypt a tarball with age (simple, modern)
brew install age  # or apt install age
age -p -o backup.tar.gz.age backup.tar.gz

# Encrypt with GPG
gpg --symmetric --cipher-algo AES256 backup.tar.gz
```

Your cloud provider can be breached. Your account can be compromised. Encryption means the attacker gets useless noise instead of your API keys.

## Cloud Storage Options

### Backblaze B2 — The Default Choice

The best balance of cheap, reliable, and easy. This is what we recommend for most people.

- **Cost:** $6/TB/month storage, $0.01/GB download
- **Free tier:** 10 GB storage, 1 GB/day downloads
- **Integration:** Native support in restic, rclone, duplicity
- **Durability:** 99.999999999% (eleven 9s)
- **Region:** US or EU

```bash
# With restic (direct)
export RESTIC_REPOSITORY="b2:your-bucket:openclaw"
export B2_ACCOUNT_ID="your-account-id"
export B2_ACCOUNT_KEY="your-account-key"
restic init
restic backup ~/.openclaw ~/hub-local

# With rclone (any tool)
rclone config  # set up B2 remote
rclone sync ~/backups/openclaw b2:your-bucket/openclaw
```

### AWS S3 / Glacier — For the Enterprise-Minded

More expensive for simple storage, but incredibly flexible. Glacier is cheap for archives you rarely access.

- **S3 Standard:** ~$23/TB/month
- **S3 Infrequent Access:** ~$12.50/TB/month
- **Glacier Instant Retrieval:** ~$4/TB/month
- **Glacier Deep Archive:** ~$1/TB/month (12-48 hour retrieval)

Use **S3 lifecycle policies** to automatically move old backups to cheaper tiers:

```json
{
  "Rules": [{
    "ID": "Archive old backups",
    "Status": "Enabled",
    "Transitions": [
      { "Days": 30, "StorageClass": "STANDARD_IA" },
      { "Days": 90, "StorageClass": "GLACIER" }
    ]
  }]
}
```

Best for: People already in the AWS ecosystem. Overkill for a single OpenClaw installation.

### rsync.net — The Nerd's Choice

A remote filesystem you can SSH into. Borg and restic work natively over SSH. No APIs, no SDKs, just `ssh` and `rsync`.

- **Cost:** ~$0.02/GB/month ($20/TB)
- **Borg/restic discount:** They offer reduced pricing for Borg/restic-only accounts
- **Interface:** SSH/SFTP — feels like a remote disk
- **Durability:** ZFS with snapshots, multiple datacenters

```bash
# With Borg
export BORG_REPO="ssh://de1234@de1234.rsync.net/./openclaw"
borg init --encryption=repokey "$BORG_REPO"
borg create "$BORG_REPO::backup-$(date +%Y-%m-%d)" ~/.openclaw ~/hub-local

# With restic
restic -r sftp:de1234@de1234.rsync.net:openclaw init
restic -r sftp:de1234@de1234.rsync.net:openclaw backup ~/.openclaw ~/hub-local
```

Best for: People who want simplicity and SSH access. Our recommendation for Tier 2 remote repos on VPS.

### Google Drive — The "I Already Have It" Option

Not ideal for programmatic backups, but works via rclone. 15 GB free.

- **Cost:** Free (15 GB), $2/month (100 GB), $3/month (200 GB), $10/month (2 TB)
- **Integration:** rclone, or NAS Cloud Sync (Synology)
- **Gotchas:** API rate limits, Google can lock your account for "suspicious activity" (bulk uploads)

```bash
rclone config  # set up Google Drive remote
rclone sync ~/backups/openclaw gdrive:openclaw-backups/
```

Best for: People who already pay for Google One and want to use the space. Not recommended as your only offsite.

## Cost Comparison

For ~50 GB of OpenClaw backups (typical with history):

| Service | Monthly Cost | Annual Cost | Notes |
|---------|-------------|-------------|-------|
| **GitHub** (Tier 1 git) | Free | Free | Private repos, ~1-2 GB |
| **Backblaze B2** | $0.30 | $3.60 | 50 GB × $6/TB |
| **rsync.net** | $1.00 | $12.00 | 50 GB × $0.02/GB |
| **AWS S3 Standard** | $1.15 | $13.80 | 50 GB × $23/TB |
| **AWS Glacier Deep** | $0.05 | $0.60 | Slow retrieval |
| **Google Drive** | Free–$2 | Free–$24 | 15 GB free |
| **Hetzner Storage Box** | €3.81 | €45.72 | 1 TB minimum, great value |

**Our recommendation for most people:** GitHub (free, Tier 1) + Backblaze B2 ($0.30/month, everything else). Total cost: $0.30/month for a complete offsite backup strategy. That's less than a single gumball.

## NAS as Intermediate Storage

If you have a Synology (or QNAP, TrueNAS, etc.), it's the perfect intermediate tier. Different physical device, always-on, and can sync to cloud automatically.

### The Synology Cloud Sync Pattern

This is what we run:

```
Your Machine → NAS → Cloud
     ↓           ↓        ↓
  (Tier 1-2)  (Tier 4a)  (Tier 4b)
```

1. **Machine → NAS:** Scripts push backups to NAS via SCP/rsync/SMB
2. **NAS → Cloud:** Synology Cloud Sync runs 24/7, syncing the backup folder to Google Drive/B2/S3

You configure Cloud Sync once in the Synology GUI and forget about it. The NAS handles upload scheduling, retry, bandwidth throttling — all the annoying stuff.

### Setup

```bash
# On your backup machine (Linux example)
# Mount NAS share
sudo mount -t cifs //nas-ip/backups /mnt/nas -o username=backup,password=xxx

# Or use SCP (see scripts/linux/backup-nas.sh)
scp ~/backups/openclaw/latest.tar.gz backup@nas-ip:/volume1/backups/openclaw/
```

On the Synology:
1. Install **Cloud Sync** from Package Center
2. Add a connection (Google Drive, Backblaze B2, S3, etc.)
3. Set sync direction: **Upload only**
4. Point it at your backup folder
5. Enable encryption (Synology Cloud Sync supports client-side encryption)

### NAS Recommendations

You don't need much for backup duty:

| Model | Bays | Price | Notes |
|-------|------|-------|-------|
| Synology DS223 | 2 | ~$200 | Budget pick, plenty for backups |
| Synology DS423 | 4 | ~$400 | Room to grow |
| QNAP TS-233 | 2 | ~$180 | Good alternative |

Put two drives in RAID 1 (mirror). A single 4 TB drive is ~$100. Total NAS setup: ~$400.

## Strategy by Paranoia Level

| Level | Strategy | Monthly Cost |
|-------|----------|-------------|
| **Minimal** | Git push to GitHub | Free |
| **Reasonable** | Git + B2 via restic/rclone | $0.30 |
| **Solid** | Git + B2 + NAS | $0.30 + NAS hardware |
| **Paranoid** | Git + B2 + NAS + rsync.net + rotating USB drives | ~$2 + hardware |

Most people should be at "Reasonable" or "Solid." If your livelihood depends on your OpenClaw setup, go "Paranoid." The marginal cost of each layer is negligible compared to the cost of losing everything.

## Common Mistakes

1. **"I'll set up offsite backup later."** — No you won't. Do it now. B2 takes 10 minutes.
2. **"My NAS is offsite enough."** — It's in the same building. Fire doesn't care about RAID.
3. **"I trust Google/AWS/GitHub to never lose data."** — They won't lose it. They might lock your account, though. Encrypt and diversify.
4. **"I'll just re-download everything."** — Your API keys? Your custom configs? Your chat history? Your trained agent's memory? Some things can't be re-downloaded.
5. **"Encryption slows things down."** — Not meaningfully. restic and Borg encrypt with negligible overhead. The excuse doesn't hold.

---

*Next: [Restore Guide](restore.md) — THE most important document in this repo.*
