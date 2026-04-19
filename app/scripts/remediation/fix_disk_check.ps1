<#
.SYNOPSIS
    Disk Check and Health Remediation Script
.DESCRIPTION
    Checks disk health by:
    - Running chkdsk on the system drive
    - Checking SMART status via wmic/CIM
    - Reporting overall disk health
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_disk_check.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_disk_check.log"
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

Write-Log "=== Disk Check Remediation Started ==="

# Step 1: Check disk space on all drives
Write-Log "Checking disk space on all volumes..."
try {
    $volumes = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }
    foreach ($vol in $volumes) {
        $freePercent = [math]::Round(($vol.SizeRemaining / $vol.Size) * 100, 1)
        $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 2)
        $totalGB = [math]::Round($vol.Size / 1GB, 2)
        if ($freePercent -lt 10) {
            Write-Log "Drive $($vol.DriveLetter): $freeGB GB free of $totalGB GB ($freePercent% free) - LOW SPACE" "ERROR"
            $ExitCode = 1
        } elseif ($freePercent -lt 20) {
            Write-Log "Drive $($vol.DriveLetter): $freeGB GB free of $totalGB GB ($freePercent% free) - Warning" "WARN"
        } else {
            Write-Log "Drive $($vol.DriveLetter): $freeGB GB free of $totalGB GB ($freePercent% free)" "SUCCESS"
        }
    }
} catch {
    Write-Log "Failed to check disk space: $_" "ERROR"
}

# Step 2: Check SMART status via CIM/WMI
Write-Log "Checking disk SMART status..."
try {
    $disks = Get-CimInstance -Namespace "root\wmi" -ClassName "MSStorageDriver_FailurePredictStatus" -ErrorAction Stop
    foreach ($disk in $disks) {
        if ($disk.PredictFailure) {
            Write-Log "SMART WARNING: Disk $($disk.InstanceName) is predicting failure!" "ERROR"
            $ExitCode = 2
        } else {
            Write-Log "SMART OK: Disk $($disk.InstanceName) reports healthy." "SUCCESS"
        }
    }
} catch {
    Write-Log "Could not query SMART status via CIM. Trying wmic..." "WARN"
    try {
        $wmicResult = & wmic diskdrive get status,model,serialNumber 2>&1 | Out-String
        Write-Log "WMIC disk status: $wmicResult" "INFO"
        if ($wmicResult -match "Pred Fail") {
            Write-Log "WMIC reports a disk is predicting failure!" "ERROR"
            $ExitCode = 2
        } elseif ($wmicResult -match "OK") {
            Write-Log "WMIC reports disk(s) OK." "SUCCESS"
        }
    } catch {
        Write-Log "Could not query disk SMART status: $_" "WARN"
    }
}

# Step 3: Check for filesystem errors in event log
Write-Log "Checking for recent disk/filesystem error events..."
try {
    $diskErrors = Get-WinEvent -LogName "System" -FilterXPath "*[System[(EventID=7 or EventID=11 or EventID=51 or EventID=55) and TimeCreated[timediff(@SystemTime) <= 604800000]]]" -MaxEvents 10 -ErrorAction SilentlyContinue
    if ($diskErrors) {
        Write-Log "Found $($diskErrors.Count) recent disk error event(s):" "WARN"
        foreach ($evt in $diskErrors) {
            Write-Log "  EventID $($evt.Id) at $($evt.TimeCreated): $($evt.Message.Substring(0, [Math]::Min(150, $evt.Message.Length)))" "WARN"
        }
        $ExitCode = [Math]::Max($ExitCode, 1)
    } else {
        Write-Log "No recent disk error events found." "SUCCESS"
    }
} catch {
    Write-Log "Could not query disk error events: $_" "WARN"
}

# Step 4: Run chkdsk (read-only scan)
Write-Log "Running chkdsk /scan on system drive (read-only online scan)..."
try {
    $systemDrive = $env:SystemDrive
    $chkdskResult = & chkdsk $systemDrive /scan 2>&1 | Out-String
    Add-Content -Path $LogFile -Value $chkdskResult
    if ($chkdskResult -match "no problems found" -or $chkdskResult -match "Windows has scanned the file system and found no problems") {
        Write-Log "chkdsk found no problems on $systemDrive." "SUCCESS"
    } elseif ($chkdskResult -match "problems found" -or $chkdskResult -match "errors") {
        Write-Log "chkdsk found issues on $systemDrive. A full chkdsk /f may be needed at next reboot." "WARN"
        $ExitCode = [Math]::Max($ExitCode, 1)
    } else {
        Write-Log "chkdsk completed. Review log for details." "INFO"
    }
} catch {
    Write-Log "chkdsk failed: $_" "ERROR"
    $ExitCode = [Math]::Max($ExitCode, 1)
}

# Step 5: Check disk performance counters
Write-Log "Checking current disk queue length..."
try {
    $diskPerf = Get-Counter '\PhysicalDisk(_Total)\Current Disk Queue Length' -SampleInterval 1 -MaxSamples 3 -ErrorAction Stop
    $avgQueue = ($diskPerf.CounterSamples | Measure-Object -Property CookedValue -Average).Average
    if ($avgQueue -gt 5) {
        Write-Log "High disk queue length ($([math]::Round($avgQueue, 2))). Disk is under heavy load." "WARN"
    } else {
        Write-Log "Disk queue length is normal ($([math]::Round($avgQueue, 2)))." "SUCCESS"
    }
} catch {
    Write-Log "Could not read disk performance counters: $_" "WARN"
}

Write-Log "=== Disk Check Remediation Completed (Exit Code: $ExitCode) ==="
exit $ExitCode
