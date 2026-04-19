<#
.SYNOPSIS
    Disk Cleanup Remediation Script
.DESCRIPTION
    Frees disk space by:
    - Cleaning temporary files (user and system)
    - Clearing Windows Update cache
    - Running Disk Cleanup (cleanmgr) with preset flags
    - Running DISM component store cleanup
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_disk_cleanup.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_disk_cleanup.log"
$ExitCode = 0

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        "WARN"    { Write-Host $entry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry -ForegroundColor Cyan }
    }
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "ERROR: This script requires Administrator privileges." -ForegroundColor Red
    exit 2
}

Write-Log "=== Disk Cleanup Remediation Started ==="

# Capture free space before cleanup
$systemDrive = $env:SystemDrive.TrimEnd(':')
$beforeFree = (Get-PSDrive $systemDrive).Free

# Step 1: Clean user temp files
Write-Log "Cleaning user temp files..."
try {
    $userTemp = $env:TEMP
    $count = 0
    Get-ChildItem -Path $userTemp -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
            $count++
        } catch {
            # File in use, skip
        }
    }
    Write-Log "Removed $count item(s) from user temp folder." "SUCCESS"
} catch {
    Write-Log "Error cleaning user temp: $_" "WARN"
}

# Step 2: Clean system temp files
Write-Log "Cleaning system temp files..."
try {
    $sysTemp = "$env:SystemRoot\Temp"
    $count = 0
    Get-ChildItem -Path $sysTemp -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
            $count++
        } catch {
            # File in use, skip
        }
    }
    Write-Log "Removed $count item(s) from system temp folder." "SUCCESS"
} catch {
    Write-Log "Error cleaning system temp: $_" "WARN"
}

# Step 3: Clear Windows Update cache
Write-Log "Clearing Windows Update cache..."
try {
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Stop-Service -Name bits -Force -ErrorAction SilentlyContinue
    $wuCache = "$env:SystemRoot\SoftwareDistribution\Download"
    if (Test-Path $wuCache) {
        $count = (Get-ChildItem -Path $wuCache -Recurse -Force -ErrorAction SilentlyContinue).Count
        Remove-Item "$wuCache\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Cleared $count item(s) from Windows Update download cache." "SUCCESS"
    }
    Start-Service -Name wuauserv -ErrorAction SilentlyContinue
    Start-Service -Name bits -ErrorAction SilentlyContinue
} catch {
    Write-Log "Error clearing WU cache: $_" "WARN"
    Start-Service -Name wuauserv -ErrorAction SilentlyContinue
    Start-Service -Name bits -ErrorAction SilentlyContinue
    $ExitCode = 1
}

# Step 4: Clear Prefetch
Write-Log "Clearing Prefetch folder..."
try {
    $prefetchPath = "$env:SystemRoot\Prefetch"
    if (Test-Path $prefetchPath) {
        $count = (Get-ChildItem -Path $prefetchPath -Force -ErrorAction SilentlyContinue).Count
        Remove-Item "$prefetchPath\*" -Force -ErrorAction SilentlyContinue
        Write-Log "Cleared $count item(s) from Prefetch." "SUCCESS"
    }
} catch {
    Write-Log "Error clearing Prefetch: $_" "WARN"
}

# Step 5: Run cleanmgr with sageset for automated cleanup
Write-Log "Running Disk Cleanup (cleanmgr)..."
try {
    # Set all cleanup categories in registry for sageset 65535
    $cleanupKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
    $categories = Get-ChildItem $cleanupKey -ErrorAction SilentlyContinue
    foreach ($cat in $categories) {
        Set-ItemProperty -Path $cat.PSPath -Name "StateFlags0100" -Value 2 -Type DWord -ErrorAction SilentlyContinue
    }
    $cleanProc = Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:100" -Wait -PassThru -ErrorAction Stop
    Write-Log "Disk Cleanup completed with exit code $($cleanProc.ExitCode)." "SUCCESS"
} catch {
    Write-Log "Disk Cleanup failed: $_" "WARN"
    $ExitCode = 1
}

# Step 6: DISM component store cleanup
Write-Log "Running DISM component store cleanup..."
try {
    $dismResult = & DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | Out-String
    Add-Content -Path $LogFile -Value $dismResult
    if ($dismResult -match "The operation completed successfully") {
        Write-Log "DISM component cleanup completed successfully." "SUCCESS"
    } else {
        Write-Log "DISM component cleanup finished. Check log for details." "INFO"
    }
} catch {
    Write-Log "DISM component cleanup failed: $_" "WARN"
    $ExitCode = 1
}

# Report space reclaimed
$afterFree = (Get-PSDrive $systemDrive).Free
$reclaimed = [math]::Round(($afterFree - $beforeFree) / 1MB, 2)
Write-Log "Space reclaimed on $($env:SystemDrive): $reclaimed MB" "SUCCESS"

Write-Log "=== Disk Cleanup Remediation Completed (Exit Code: $ExitCode) ==="
exit $ExitCode
