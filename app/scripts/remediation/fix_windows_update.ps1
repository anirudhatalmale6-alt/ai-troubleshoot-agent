<#
.SYNOPSIS
    Windows Update Reset Remediation Script
.DESCRIPTION
    Resets Windows Update components by:
    - Stopping Windows Update related services
    - Renaming SoftwareDistribution and catroot2 folders
    - Re-registering Windows Update DLLs
    - Restarting services
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_windows_update.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_windows_update.log"
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

Write-Log "=== Windows Update Reset Started ==="

# Step 1: Stop Windows Update services
$services = @("wuauserv", "bits", "cryptsvc", "msiserver", "appidsvc")
Write-Log "Stopping Windows Update services..."
foreach ($svc in $services) {
    try {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq "Running") {
            Stop-Service -Name $svc -Force -ErrorAction Stop
            Write-Log "Stopped service: $svc" "SUCCESS"
        } else {
            Write-Log "Service $svc is already stopped or not found." "INFO"
        }
    } catch {
        Write-Log "Failed to stop $svc : $_" "WARN"
    }
}

# Step 2: Rename SoftwareDistribution folder
Write-Log "Renaming SoftwareDistribution folder..."
try {
    $sdPath = "$env:SystemRoot\SoftwareDistribution"
    $backupName = "SoftwareDistribution.old_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    if (Test-Path $sdPath) {
        Rename-Item -Path $sdPath -NewName $backupName -Force -ErrorAction Stop
        Write-Log "Renamed SoftwareDistribution to $backupName" "SUCCESS"
    } else {
        Write-Log "SoftwareDistribution folder not found." "WARN"
    }
} catch {
    Write-Log "Failed to rename SoftwareDistribution: $_" "ERROR"
    $ExitCode = 1
}

# Step 3: Rename catroot2 folder
Write-Log "Renaming catroot2 folder..."
try {
    $catrootPath = "$env:SystemRoot\System32\catroot2"
    $backupName = "catroot2.old_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    if (Test-Path $catrootPath) {
        Rename-Item -Path $catrootPath -NewName $backupName -Force -ErrorAction Stop
        Write-Log "Renamed catroot2 to $backupName" "SUCCESS"
    } else {
        Write-Log "catroot2 folder not found." "WARN"
    }
} catch {
    Write-Log "Failed to rename catroot2: $_" "ERROR"
    $ExitCode = 1
}

# Step 4: Re-register Windows Update DLLs
Write-Log "Re-registering Windows Update DLLs..."
$dlls = @(
    "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll",
    "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll",
    "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll",
    "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
    "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll",
    "wuaueng.dll", "wuaueng1.dll", "wucltui.dll", "wups.dll", "wups2.dll",
    "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll",
    "wuwebv.dll"
)

$regSuccess = 0
$regFail = 0
foreach ($dll in $dlls) {
    try {
        $result = & regsvr32.exe /s "$env:SystemRoot\System32\$dll" 2>&1
        $regSuccess++
    } catch {
        $regFail++
    }
}
Write-Log "DLL registration: $regSuccess succeeded, $regFail failed." $(if ($regFail -eq 0) { "SUCCESS" } else { "WARN" })

# Step 5: Reset Winsock (can help with WU network issues)
Write-Log "Resetting Winsock catalog..."
try {
    $netshResult = & netsh winsock reset 2>&1 | Out-String
    Write-Log "Winsock reset: $($netshResult.Trim())" "SUCCESS"
} catch {
    Write-Log "Winsock reset failed: $_" "WARN"
}

# Step 6: Restart Windows Update services
Write-Log "Restarting Windows Update services..."
foreach ($svc in $services) {
    try {
        Start-Service -Name $svc -ErrorAction SilentlyContinue
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq "Running") {
            Write-Log "Started service: $svc" "SUCCESS"
        } else {
            Write-Log "Service $svc may not have started (Status: $($service.Status))." "WARN"
        }
    } catch {
        Write-Log "Failed to start $svc : $_" "WARN"
    }
}

# Step 7: Force Windows Update detection
Write-Log "Triggering Windows Update detection..."
try {
    $updateSession = New-Object -ComObject Microsoft.Update.AutoUpdate
    $updateSession.DetectNow()
    Write-Log "Windows Update detection triggered." "SUCCESS"
} catch {
    Write-Log "Could not trigger WU detection: $_" "WARN"
}

Write-Log "=== Windows Update Reset Completed (Exit Code: $ExitCode) ==="
Write-Log "A reboot is recommended after this operation." "WARN"
exit $ExitCode
