# =============================================================================
# Tier 2: File-Level Backup with Robocopy (Windows)
# =============================================================================
# Robocopy is built into Windows. It's not as fancy as Borg/restic (no
# deduplication or encryption), but it's reliable, fast, and zero-install.
#
# This creates a mirror of your OpenClaw files to a backup directory.
# For encryption, use BitLocker on the backup drive.
# For deduplication, consider installing restic via scoop/chocolatey instead.
#
# Usage: .\backup-robocopy.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptDir)) ".env"

function Load-EnvFile($Path) {
    if (Test-Path $Path) {
        Get-Content $Path | ForEach-Object {
            if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim().Trim('"').Trim("'")
                $val = $val -replace '\$\{?HOME\}?', $env:USERPROFILE
                [Environment]::SetEnvironmentVariable($key, $val, "Process")
            }
        }
    }
}

Load-EnvFile $EnvFile

$OpenclawHome = if ($env:OPENCLAW_HOME) { $env:OPENCLAW_HOME } else { Join-Path $env:USERPROFILE ".openclaw" }
$OpenclawWorkspace = if ($env:OPENCLAW_WORKSPACE) { $env:OPENCLAW_WORKSPACE } else { Join-Path $env:USERPROFILE "hub-local" }
$BackupDir = if ($env:BACKUP_DIR) { $env:BACKUP_DIR } else { Join-Path $env:USERPROFILE "backups\openclaw" }
$LogDir = if ($env:LOG_DIR) { $env:LOG_DIR } else { Join-Path $env:USERPROFILE "logs\openclaw-backup" }

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$LogFile = Join-Path $LogDir "robocopy.log"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Log "--- Robocopy backup starting ---"

# Step 1: Safe SQLite backup
Log "Snapshotting databases..."
$NodePath = (Get-Command node -ErrorAction SilentlyContinue).Source
if ($NodePath) {
    $CommonDb = Join-Path $ScriptDir "..\common\backup-db.js"
    & node $CommonDb 2>&1 | ForEach-Object { Log $_ }
}

# Step 2: Robocopy OpenClaw home
$Dest1 = Join-Path $BackupDir "openclaw-home"
Log "Backing up OpenClaw home: $OpenclawHome → $Dest1"

$excludeDirs = @("node_modules", ".git", "__pycache__")
$excludeFiles = @("*.log", "*.tmp")

robocopy $OpenclawHome $Dest1 /MIR /NFL /NDL /NP /MT:4 `
    /XD $excludeDirs `
    /XF $excludeFiles `
    /LOG+:$LogFile /TEE

# Robocopy exit codes: 0-7 are success, 8+ are errors
if ($LASTEXITCODE -ge 8) {
    Log "✗ Robocopy failed for OpenClaw home (exit code: $LASTEXITCODE)"
} else {
    Log "✓ OpenClaw home backed up"
}

# Step 3: Robocopy workspace
$Dest2 = Join-Path $BackupDir "workspace"
Log "Backing up workspace: $OpenclawWorkspace → $Dest2"

robocopy $OpenclawWorkspace $Dest2 /MIR /NFL /NDL /NP /MT:4 `
    /XD $excludeDirs `
    /XF $excludeFiles `
    /LOG+:$LogFile /TEE

if ($LASTEXITCODE -ge 8) {
    Log "✗ Robocopy failed for workspace (exit code: $LASTEXITCODE)"
} else {
    Log "✓ Workspace backed up"
}

# Step 4: Create timestamped snapshot (keep last 7)
$SnapshotDir = Join-Path $BackupDir "snapshots"
New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$SnapshotFile = Join-Path $SnapshotDir "openclaw-$timestamp.zip"

Log "Creating snapshot: $SnapshotFile"
Compress-Archive -Path $Dest1, $Dest2 -DestinationPath $SnapshotFile -Force

$snapSize = (Get-Item $SnapshotFile).Length / 1MB
Log "✓ Snapshot created ($([math]::Round($snapSize, 1)) MB)"

# Prune old snapshots
$snapshots = Get-ChildItem $SnapshotDir -Filter "openclaw-*.zip" | Sort-Object Name -Descending
if ($snapshots.Count -gt 7) {
    $toRemove = $snapshots | Select-Object -Skip 7
    foreach ($snap in $toRemove) {
        Remove-Item $snap.FullName -Force
        Log "Pruned old snapshot: $($snap.Name)"
    }
}

Log "✓ Robocopy backup complete"
