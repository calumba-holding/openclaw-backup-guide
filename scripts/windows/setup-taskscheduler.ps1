# =============================================================================
# Setup Windows Task Scheduler for OpenClaw Backups
# =============================================================================
# Creates scheduled tasks for all backup tiers. Safe to re-run (idempotent).
# Requires Administrator privileges for some tasks.
#
# Usage: Run as Administrator
#   .\setup-taskscheduler.ps1
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

Write-Host "🛡️  OpenClaw Backup Task Scheduler Setup" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# Helper to create or update a scheduled task
function Ensure-BackupTask {
    param(
        [string]$Name,
        [string]$Description,
        [string]$ScriptPath,
        $Trigger,
        [switch]$RunElevated
    )
    
    $taskName = "OpenClaw\$Name"
    
    # Remove existing task
    $existing = Get-ScheduledTask -TaskName $Name -TaskPath "\OpenClaw\" -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $Name -TaskPath "\OpenClaw\" -Confirm:$false
    }
    
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
        -WorkingDirectory (Split-Path $ScriptPath)
    
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable:$false `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    
    $principal = if ($RunElevated) {
        New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    } else {
        New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    }
    
    Register-ScheduledTask `
        -TaskName $Name `
        -TaskPath "\OpenClaw\" `
        -Action $action `
        -Trigger $Trigger `
        -Settings $settings `
        -Principal $principal `
        -Description $Description `
        -Force | Out-Null
    
    Write-Host "  ✓ $Name" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Tier 1: Git backup — every hour
# ---------------------------------------------------------------------------
Write-Host "Installing Tier 1 (Git backup - hourly)..."
$gitTrigger = New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 365)
Ensure-BackupTask `
    -Name "Backup-Git" `
    -Description "OpenClaw Tier 1: Git commit and push (hourly)" `
    -ScriptPath (Join-Path $ScriptDir "backup-git.ps1") `
    -Trigger $gitTrigger

# ---------------------------------------------------------------------------
# Tier 2: Robocopy — 3x daily
# ---------------------------------------------------------------------------
Write-Host "Installing Tier 2 (Robocopy - 3x daily)..."
$robocopyTriggers = @(
    (New-ScheduledTaskTrigger -Daily -At "08:00"),
    (New-ScheduledTaskTrigger -Daily -At "14:00"),
    (New-ScheduledTaskTrigger -Daily -At "22:00")
)
# Task Scheduler supports multiple triggers
foreach ($i in 0..2) {
    $suffix = @("Morning", "Afternoon", "Night")[$i]
    Ensure-BackupTask `
        -Name "Backup-Robocopy-$suffix" `
        -Description "OpenClaw Tier 2: Robocopy file backup ($suffix)" `
        -ScriptPath (Join-Path $ScriptDir "backup-robocopy.ps1") `
        -Trigger $robocopyTriggers[$i]
}

# ---------------------------------------------------------------------------
# Verification — weekly
# ---------------------------------------------------------------------------
Write-Host "Installing verification (weekly Sunday 6am)..."
$verifyScript = Join-Path $ScriptDir "..\common\verify-backup.sh"
# On Windows, run verify via WSL if available, otherwise skip
$wslPath = (Get-Command wsl -ErrorAction SilentlyContinue).Source
if ($wslPath) {
    $verifyTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "06:00"
    $verifyAction = New-ScheduledTaskAction `
        -Execute "wsl" `
        -Argument "bash -c '$verifyScript'"
    
    $existing = Get-ScheduledTask -TaskName "Verify-Backup" -TaskPath "\OpenClaw\" -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName "Verify-Backup" -TaskPath "\OpenClaw\" -Confirm:$false
    }
    
    Register-ScheduledTask `
        -TaskName "Verify-Backup" `
        -TaskPath "\OpenClaw\" `
        -Action $verifyAction `
        -Trigger $verifyTrigger `
        -Description "OpenClaw: Weekly backup verification" `
        -Force | Out-Null
    
    Write-Host "  ✓ Verify-Backup (via WSL)" -ForegroundColor Green
} else {
    Write-Host "  ⚠ WSL not found — skipping verify task (install WSL for full features)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "🎉 Setup complete!" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Installed tasks:"
Get-ScheduledTask -TaskPath "\OpenClaw\" | Format-Table TaskName, State, @{N='Next Run';E={($_ | Get-ScheduledTaskInfo).NextRunTime}} -AutoSize
Write-Host ""
Write-Host "Manage tasks:"
Write-Host "  View:    Get-ScheduledTask -TaskPath '\OpenClaw\'"
Write-Host "  Run now: Start-ScheduledTask -TaskPath '\OpenClaw\' -TaskName 'Backup-Git'"
Write-Host "  Remove:  Get-ScheduledTask -TaskPath '\OpenClaw\' | Unregister-ScheduledTask"
Write-Host ""
Write-Host "Logs: $LogDir"
