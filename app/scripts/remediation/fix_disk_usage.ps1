<#
.SYNOPSIS
    Disk I/O Usage Remediation Script
.DESCRIPTION
    Reduces high disk I/O by:
    - Identifying processes with high disk I/O
    - Disabling SysMain/Superfetch if running on HDD
    - Temporarily disabling Windows Search indexing
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_disk_usage.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_disk_usage.log"
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

Write-Log "=== Disk Usage Remediation Started ==="

# Step 1: Identify top disk I/O processes
Write-Log "Identifying processes with high disk I/O..."
try {
    $processes = Get-Process | Where-Object { $_.Id -ne 0 } | Sort-Object -Property @{Expression={$_.IO.ReadBytes + $_.IO.WriteBytes}} -Descending -ErrorAction SilentlyContinue | Select-Object -First 10
    Write-Log "Top 10 processes by total I/O:" "INFO"
    foreach ($proc in $processes) {
        $readMB = [math]::Round($proc.IO.ReadBytes / 1MB, 2)
        $writeMB = [math]::Round($proc.IO.WriteBytes / 1MB, 2)
        Write-Log "  PID $($proc.Id) - $($proc.ProcessName): Read=$readMB MB, Write=$writeMB MB" "INFO"
    }
} catch {
    Write-Log "Could not enumerate disk I/O processes: $_" "WARN"
}

# Step 2: Check current disk usage via performance counters
Write-Log "Checking current disk utilization..."
try {
    $diskTime = Get-Counter '\PhysicalDisk(_Total)\% Disk Time' -SampleInterval 2 -MaxSamples 3 -ErrorAction Stop
    $avgDisk = [math]::Round(($diskTime.CounterSamples | Measure-Object -Property CookedValue -Average).Average, 1)
    if ($avgDisk -gt 80) {
        Write-Log "Disk utilization is very high: $avgDisk%. Taking corrective action." "ERROR"
    } elseif ($avgDisk -gt 50) {
        Write-Log "Disk utilization is elevated: $avgDisk%." "WARN"
    } else {
        Write-Log "Disk utilization is normal: $avgDisk%." "SUCCESS"
    }
} catch {
    Write-Log "Could not read disk performance counters: $_" "WARN"
}

# Step 3: Detect if system drive is HDD or SSD
Write-Log "Detecting disk type (HDD vs SSD)..."
$isHDD = $false
try {
    $diskInfo = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq 0 }
    if ($diskInfo.MediaType -eq "HDD" -or $diskInfo.MediaType -eq "Unspecified") {
        Write-Log "System disk appears to be HDD (MediaType: $($diskInfo.MediaType))." "WARN"
        $isHDD = $true
    } else {
        Write-Log "System disk is SSD (MediaType: $($diskInfo.MediaType))." "SUCCESS"
    }
} catch {
    Write-Log "Could not determine disk type. Assuming HDD for safety." "WARN"
    $isHDD = $true
}

# Step 4: Disable SysMain/Superfetch if on HDD
if ($isHDD) {
    Write-Log "Disabling SysMain (Superfetch) service for HDD optimization..."
    try {
        $sysMain = Get-Service -Name "SysMain" -ErrorAction SilentlyContinue
        if ($sysMain -and $sysMain.Status -eq "Running") {
            Stop-Service -Name "SysMain" -Force -ErrorAction Stop
            Set-Service -Name "SysMain" -StartupType Disabled -ErrorAction Stop
            Write-Log "SysMain service stopped and disabled." "SUCCESS"
        } elseif ($sysMain) {
            Write-Log "SysMain is already stopped (Status: $($sysMain.Status))." "INFO"
        } else {
            # Try legacy name
            $superfetch = Get-Service -Name "Superfetch" -ErrorAction SilentlyContinue
            if ($superfetch -and $superfetch.Status -eq "Running") {
                Stop-Service -Name "Superfetch" -Force -ErrorAction Stop
                Set-Service -Name "Superfetch" -StartupType Disabled -ErrorAction Stop
                Write-Log "Superfetch service stopped and disabled." "SUCCESS"
            } else {
                Write-Log "SysMain/Superfetch service not found or already stopped." "INFO"
            }
        }
    } catch {
        Write-Log "Failed to disable SysMain: $_" "ERROR"
        $ExitCode = 1
    }
} else {
    Write-Log "SSD detected; skipping SysMain disable (SysMain benefits SSDs)." "INFO"
}

# Step 5: Temporarily disable Windows Search indexing
Write-Log "Stopping Windows Search indexing temporarily..."
try {
    $wsearch = Get-Service -Name "WSearch" -ErrorAction SilentlyContinue
    if ($wsearch -and $wsearch.Status -eq "Running") {
        Stop-Service -Name "WSearch" -Force -ErrorAction Stop
        Write-Log "Windows Search service stopped. It will restart automatically or at next boot." "SUCCESS"
        Write-Log "To permanently disable, run: Set-Service -Name WSearch -StartupType Disabled" "INFO"
    } else {
        Write-Log "Windows Search is already stopped." "INFO"
    }
} catch {
    Write-Log "Failed to stop Windows Search: $_" "WARN"
}

# Step 6: Check for known high-IO background tasks
Write-Log "Checking for known high-IO background processes..."
try {
    $knownHogs = @("SearchIndexer", "CompatTelRunner", "MsMpEng", "TiWorker", "WUDFHost", "svchost")
    foreach ($name in $knownHogs) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($procs) {
            foreach ($p in $procs) {
                $cpuTime = [math]::Round($p.TotalProcessorTime.TotalSeconds, 1)
                $ws = [math]::Round($p.WorkingSet64 / 1MB, 1)
                Write-Log "  $name (PID $($p.Id)): CPU=$cpuTime s, Memory=$ws MB" "INFO"
            }
        }
    }
} catch {
    Write-Log "Error checking background processes: $_" "WARN"
}

Write-Log "=== Disk Usage Remediation Completed (Exit Code: $ExitCode) ==="
exit $ExitCode
