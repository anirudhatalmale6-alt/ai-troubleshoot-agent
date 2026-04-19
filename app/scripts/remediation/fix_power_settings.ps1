# ============================================================
# Power Settings Fix Script
# Disables fast startup, runs power diagnostics
# ============================================================
$LogFile = "$env:TEMP\TroubleshootAgent_power_settings.log"
$ExitCode = 0

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $msg" | Tee-Object -FilePath $LogFile -Append
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Run as Administrator!" -ForegroundColor Red
    exit 2
}

Log "Starting power settings fix..."

try {
    # Step 1: Disable Fast Startup
    Write-Host "Disabling Fast Startup..." -ForegroundColor Yellow
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
    Set-ItemProperty -Path $regPath -Name "HiberbootEnabled" -Value 0 -ErrorAction SilentlyContinue
    Log "Fast Startup disabled."
    Write-Host "Fast Startup disabled." -ForegroundColor Green

    # Step 2: Set power plan to High Performance
    Write-Host "Checking power plan..." -ForegroundColor Yellow
    $plans = powercfg /list 2>&1
    Log "Power plans: $plans"
    Write-Host $plans -ForegroundColor Cyan

    # Step 3: Run power diagnostics
    Write-Host "Running power efficiency diagnostics..." -ForegroundColor Yellow
    $reportPath = "$env:TEMP\power_report.html"
    powercfg /energy /output $reportPath /duration 10 2>&1
    if (Test-Path $reportPath) {
        Write-Host "Power report saved to: $reportPath" -ForegroundColor Green
        Log "Power report generated: $reportPath"
    }

    # Step 4: Check sleep/wake settings
    Write-Host "Checking last sleep states..." -ForegroundColor Yellow
    $sleepInfo = powercfg /lastwake 2>&1
    Log "Last wake: $sleepInfo"
    Write-Host $sleepInfo -ForegroundColor Cyan

    # Step 5: Check for wake timers
    Write-Host "Checking wake timers..." -ForegroundColor Yellow
    $wakeTimers = powercfg /waketimers 2>&1
    Log "Wake timers: $wakeTimers"
    Write-Host $wakeTimers -ForegroundColor Cyan

    # Step 6: Disable hibernate if on desktop
    Write-Host "Checking hibernate status..." -ForegroundColor Yellow
    $battery = Get-WmiObject -Class Win32_Battery -ErrorAction SilentlyContinue
    if (-not $battery) {
        Write-Host "Desktop detected. Disabling hibernate to free disk space..." -ForegroundColor Yellow
        powercfg /hibernate off 2>&1
        Log "Hibernate disabled (desktop)."
    }

    Write-Host "Power settings fix complete." -ForegroundColor Green
    Log "Complete."
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Log "ERROR: $($_.Exception.Message)"
    $ExitCode = 2
}

exit $ExitCode
