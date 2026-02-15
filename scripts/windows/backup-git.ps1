# =============================================================================
# Tier 1: Git Backup (Windows PowerShell)
# =============================================================================
# 1. Safely snapshot SQLite databases
# 2. git add -A && git commit && git push
#
# Usage: .\backup-git.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

# Load config
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptDir)) ".env"

# Simple .env loader
function Load-EnvFile($Path) {
    if (Test-Path $Path) {
        Get-Content $Path | ForEach-Object {
            if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim().Trim('"').Trim("'")
                # Expand $HOME and ${HOME}
                $val = $val -replace '\$\{?HOME\}?', $env:USERPROFILE
                [Environment]::SetEnvironmentVariable($key, $val, "Process")
            }
        }
    }
}

Load-EnvFile $EnvFile

$OpenclawWorkspace = if ($env:OPENCLAW_WORKSPACE) { $env:OPENCLAW_WORKSPACE } else { Join-Path $env:USERPROFILE "hub-local" }
$GitRemote = if ($env:GIT_REMOTE) { $env:GIT_REMOTE } else { "origin" }
$GitBranch = if ($env:GIT_BRANCH) { $env:GIT_BRANCH } else { "main" }
$LogDir = if ($env:LOG_DIR) { $env:LOG_DIR } else { Join-Path $env:USERPROFILE "logs\openclaw-backup" }

# Ensure log directory exists
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "git.log"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Log "--- Git backup starting ---"

# Step 1: Safe SQLite backup
Log "Snapshotting databases..."
$NodePath = (Get-Command node -ErrorAction SilentlyContinue).Source
if ($NodePath) {
    $CommonDb = Join-Path $ScriptDir "..\common\backup-db.js"
    & node $CommonDb 2>&1 | ForEach-Object { Log $_ }
} else {
    Log "WARNING: Node.js not found. Install from https://nodejs.org"
}

# Step 2: Git commit and push
Set-Location $OpenclawWorkspace

if (-not (Test-Path ".git")) {
    Log "ERROR: $OpenclawWorkspace is not a git repository."
    exit 1
}

# Check for changes
$status = git status --porcelain 2>&1
if ([string]::IsNullOrWhiteSpace($status)) {
    Log "No changes to commit. Skipping."
    exit 0
}

git add -A
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$hostname = $env:COMPUTERNAME
git commit -m "backup: $timestamp [$hostname]" --no-verify 2>&1 | ForEach-Object { Log $_ }

try {
    git push $GitRemote $GitBranch 2>&1 | ForEach-Object { Log $_ }
    Log "✓ Git backup complete — committed and pushed."
} catch {
    Log "✗ Push failed: $_"
    exit 1
}
