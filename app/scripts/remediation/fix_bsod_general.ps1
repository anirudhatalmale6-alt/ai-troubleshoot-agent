<#
.SYNOPSIS
    BSOD General Remediation Script
.DESCRIPTION
    Attempts to fix common Blue Screen of Death causes by:
    - Running System File Checker (sfc /scannow)
    - Running DISM image repair
    - Checking Windows Memory Diagnostic results
    - Triggering driver updates via Windows Update
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_bsod_general.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_bsod_general.log"
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

# Check for admin privileges
function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "ERROR: This script requires Administrator privileges. Please run as Administrator." -ForegroundColor Red
    exit 2
}

Write-Log "=== BSOD General Remediation Started ==="

# Step 1: System File Checker
Write-Log "Running System File Checker (sfc /scannow)..."
try {
    $sfcResult = & sfc /scannow 2>&1 | Out-String
    Write-Log "SFC output captured."
    if ($sfcResult -match "found corrupt files and successfully repaired") {
        Write-Log "SFC found and repaired corrupt files." "SUCCESS"
    } elseif ($sfcResult -match "did not find any integrity violations") {
        Write-Log "SFC found no integrity violations." "SUCCESS"
    } elseif ($sfcResult -match "found corrupt files but was unable to fix") {
        Write-Log "SFC found corrupt files but could not fix them. DISM may help." "WARN"
        $ExitCode = 1
    } else {
        Write-Log "SFC completed with unknown result. Check log for details." "WARN"
        $ExitCode = 1
    }
    Add-Content -Path $LogFile -Value $sfcResult
} catch {
    Write-Log "SFC failed: $_" "ERROR"
    $ExitCode = 1
}

# Step 2: DISM Image Repair
Write-Log "Running DISM RestoreHealth..."
try {
    $dismResult = & DISM /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-String
    Write-Log "DISM output captured."
    if ($dismResult -match "The restore operation completed successfully") {
        Write-Log "DISM RestoreHealth completed successfully." "SUCCESS"
    } else {
        Write-Log "DISM completed but may not have fully succeeded." "WARN"
        $ExitCode = 1
    }
    Add-Content -Path $LogFile -Value $dismResult
} catch {
    Write-Log "DISM failed: $_" "ERROR"
    $ExitCode = 1
}

# Step 3: Check Windows Memory Diagnostic results
Write-Log "Checking Windows Memory Diagnostic results from Event Log..."
try {
    $memEvents = Get-WinEvent -LogName "System" -FilterXPath "*[System[Provider[@Name='Microsoft-Windows-MemoryDiagnostics-Results']]]" -MaxEvents 5 -ErrorAction SilentlyContinue
    if ($memEvents) {
        foreach ($evt in $memEvents) {
            Write-Log "Memory Diagnostic Event ($($evt.TimeCreated)): $($evt.Message)" "INFO"
            if ($evt.Message -match "hardware problems were detected") {
                Write-Log "MEMORY HARDWARE ISSUES DETECTED. Consider replacing RAM." "ERROR"
                $ExitCode = 1
            }
        }
    } else {
        Write-Log "No Memory Diagnostic results found. Consider running Windows Memory Diagnostic (mdsched.exe) and rebooting." "WARN"
    }
} catch {
    Write-Log "Could not read Memory Diagnostic events: $_" "WARN"
}

# Step 4: Trigger driver updates via Windows Update
Write-Log "Checking for driver updates via Windows Update..."
try {
    $updateSession = New-Object -ComObject Microsoft.Update.Session
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    $searchResult = $updateSearcher.Search("IsInstalled=0 and Type='Driver'")
    if ($searchResult.Updates.Count -gt 0) {
        Write-Log "Found $($searchResult.Updates.Count) driver update(s) available:" "WARN"
        foreach ($update in $searchResult.Updates) {
            Write-Log "  - $($update.Title)" "INFO"
        }
        Write-Log "Installing driver updates..."
        $updatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($update in $searchResult.Updates) {
            $updatesToInstall.Add($update) | Out-Null
        }
        $downloader = $updateSession.CreateUpdateDownloader()
        $downloader.Updates = $updatesToInstall
        $downloader.Download() | Out-Null
        $installer = $updateSession.CreateUpdateInstaller()
        $installer.Updates = $updatesToInstall
        $installResult = $installer.Install()
        Write-Log "Driver updates installed. Result code: $($installResult.ResultCode)" "SUCCESS"
    } else {
        Write-Log "No pending driver updates found." "SUCCESS"
    }
} catch {
    Write-Log "Driver update check failed: $_" "WARN"
    Write-Log "You can manually check for driver updates via Settings > Windows Update > Advanced > Optional updates." "INFO"
}

# Step 5: Check recent BSOD events
Write-Log "Checking recent BSOD/BugCheck events..."
try {
    $bsodEvents = Get-WinEvent -LogName "System" -FilterXPath "*[System[EventID=1001 and Provider[@Name='Microsoft-Windows-WER-SystemErrorReporting']]]" -MaxEvents 5 -ErrorAction SilentlyContinue
    if ($bsodEvents) {
        Write-Log "Recent BSOD events found:" "WARN"
        foreach ($evt in $bsodEvents) {
            Write-Log "  BSOD on $($evt.TimeCreated): $($evt.Message.Substring(0, [Math]::Min(200, $evt.Message.Length)))" "WARN"
        }
    } else {
        Write-Log "No recent BSOD events found in System log." "SUCCESS"
    }
} catch {
    Write-Log "Could not query BSOD events: $_" "WARN"
}

Write-Log "=== BSOD General Remediation Completed (Exit Code: $ExitCode) ==="
exit $ExitCode
