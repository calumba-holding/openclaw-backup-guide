# =============================================================================
# Tier 3: Veeam Agent (Free) System Image Backup
# =============================================================================
# Veeam Agent for Microsoft Windows (FREE edition) creates full system images.
# It's the best free option for bare-metal Windows recovery.
#
# Prerequisites:
#   1. Download Veeam Agent FREE: https://www.veeam.com/windows-endpoint-server-backup-free.html
#   2. Install and configure a backup job via the GUI (first time only)
#   3. This script triggers the existing job and monitors it
#
# Usage: .\backup-veeam.ps1
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

$LogDir = if ($env:LOG_DIR) { $env:LOG_DIR } else { Join-Path $env:USERPROFILE "logs\openclaw-backup" }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "veeam.log"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Log "--- Veeam image backup starting ---"

# Check if Veeam Agent is installed
$VeeamPath = "C:\Program Files\Veeam\Endpoint Backup"
$VeeamCli = Join-Path $VeeamPath "Veeam.EndPoint.Manager.exe"

if (-not (Test-Path $VeeamCli)) {
    Log "ERROR: Veeam Agent not found at $VeeamPath"
    Log ""
    Log "Install Veeam Agent FREE:"
    Log "  1. Download: https://www.veeam.com/windows-endpoint-server-backup-free.html"
    Log "  2. Install (free, no license key needed)"
    Log "  3. Configure a backup job via the Veeam GUI:"
    Log "     - Type: Entire Computer"
    Log "     - Destination: External drive or network share"
    Log "     - Schedule: Monthly (or as desired)"
    Log "  4. Then this script can trigger it on-demand"
    exit 1
}

# Check for Veeam PowerShell module
$VeeamPSPath = Join-Path $VeeamPath "Veeam.Backup.PowerShell"
if (Test-Path $VeeamPSPath) {
    try {
        Import-Module (Join-Path $VeeamPSPath "Veeam.Backup.PowerShell.psd1") -ErrorAction Stop
        Log "Veeam PowerShell module loaded"
    } catch {
        Log "Could not load Veeam PowerShell module — using CLI fallback"
    }
}

# Try to start the backup job
# Veeam Agent uses Windows services, so we trigger via the scheduled task
$taskName = "Veeam Agent for Microsoft Windows"
$task = Get-ScheduledTask -TaskName "*Veeam*" -ErrorAction SilentlyContinue | Select-Object -First 1

if ($task) {
    Log "Found Veeam task: $($task.TaskName)"
    Log "Current state: $($task.State)"
    
    if ($task.State -eq "Running") {
        Log "Veeam backup is already running. Skipping."
    } else {
        Log "Starting Veeam backup..."
        Start-ScheduledTask -TaskName $task.TaskName
        Log "✓ Veeam backup triggered. Monitor in Veeam Agent tray icon."
    }
} else {
    Log "No Veeam scheduled task found."
    Log "Configure a backup job in the Veeam Agent GUI first."
    Log ""
    Log "Alternative: Run Veeam Agent manually from the Start Menu."
    Log "After configuring a job, this script will be able to trigger it."
    exit 1
}

Log ""
Log "=== Veeam Backup Tips ==="
Log "• First backup is FULL (takes hours). Subsequent ones are incremental."
Log "• Use an external USB drive or network share as the destination."
Log "• Test recovery with Veeam Recovery Media (create it from the GUI)."
Log "• Keep the Veeam Recovery USB drive somewhere safe."
