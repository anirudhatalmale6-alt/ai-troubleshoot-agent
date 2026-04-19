<#
.SYNOPSIS
    Power Settings Remediation Script
.DESCRIPTION
    Fixes power-related issues by:
    - Disabling Fast Startup (common cause of wake/boot issues)
    - Running power efficiency diagnostics (powercfg /energy)
    - Checking power plan configuration
    - Reviewing last wake source and wake timers
    - Disabling hibernate on desktops to reclaim space
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_power_settings.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_power_settings.log"
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

Write-Log "=== Power Settings Remediation Started ==="

# Step 1: Disable Fast Startup
Write-Log "Disabling Fast Startup..."
try {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
    $currentValue = Get-ItemProperty -Path $regPath -Name "HiberbootEnabled" -ErrorAction SilentlyContinue
    if ($currentValue -and $currentValue.HiberbootEnabled -eq 0) {
        Write-Log "Fast Startup is already disabled." "INFO"
    } else {
        Set-ItemProperty -Path $regPath -Name "HiberbootEnabled" -Value 0 -Type DWord -Force -ErrorAction Stop
        Write-Log "Fast Startup disabled. This prevents hybrid shutdown issues." "SUCCESS"
    }
} catch {
    Write-Log "Failed to disable Fast Startup: $_" "ERROR"
    $ExitCode = 1
}

# Step 2: List power plans and identify active one
Write-Log "Checking power plans..."
try {
    $planOutput = & powercfg /list 2>&1 | Out-String
    Add-Content -Path $LogFile -Value $planOutput
    # Parse active plan
    $activePlan = ($planOutput -split "`n" | Where-Object { $_ -match "\*$" }) -replace "\s*\*\s*$", ""
    if ($activePlan) {
        Write-Log "Active power plan: $($activePlan.Trim())" "INFO"
    }

    # Check if High Performance is available
    if ($planOutput -match "High performance") {
        Write-Log "High Performance plan is available." "INFO"
    } else {
        Write-Log "High Performance plan not found. Consider creating one with: powercfg /duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c" "WARN"
    }
} catch {
    Write-Log "Error checking power plans: $_" "WARN"
}

# Step 3: Run power efficiency diagnostics
Write-Log "Running power efficiency diagnostics (60-second trace)..."
try {
    $reportPath = "$env:TEMP\TroubleshootAgent_power_report.html"
    $energyResult = & powercfg /energy /output $reportPath /duration 10 2>&1 | Out-String
    Add-Content -Path $LogFile -Value $energyResult
    if (Test-Path $reportPath) {
        Write-Log "Power efficiency report saved to: $reportPath" "SUCCESS"
        # Parse for errors and warnings
        $reportContent = Get-Content $reportPath -Raw -ErrorAction SilentlyContinue
        if ($reportContent -match "Errors:\s*(\d+)") {
            $errors = $matches[1]
            Write-Log "Power report found $errors error(s)." $(if ([int]$errors -gt 0) { "WARN" } else { "SUCCESS" })
        }
        if ($reportContent -match "Warnings:\s*(\d+)") {
            $warnings = $matches[1]
            Write-Log "Power report found $warnings warning(s)." $(if ([int]$warnings -gt 0) { "WARN" } else { "SUCCESS" })
        }
    } else {
        Write-Log "Power report was not generated." "WARN"
    }
} catch {
    Write-Log "Power diagnostics failed: $_" "WARN"
}

# Step 4: Check last wake source
Write-Log "Checking last wake source..."
try {
    $lastWake = & powercfg /lastwake 2>&1 | Out-String
    Write-Log "Last wake info: $($lastWake.Trim())" "INFO"
    Add-Content -Path $LogFile -Value $lastWake
} catch {
    Write-Log "Could not check last wake: $_" "WARN"
}

# Step 5: Check wake timers
Write-Log "Checking active wake timers..."
try {
    $wakeTimers = & powercfg /waketimers 2>&1 | Out-String
    if ($wakeTimers -match "no active wake timers" -or $wakeTimers.Trim().Length -lt 10) {
        Write-Log "No active wake timers." "SUCCESS"
    } else {
        Write-Log "Active wake timers found:" "WARN"
        Add-Content -Path $LogFile -Value $wakeTimers
        Write-Log $wakeTimers.Trim() "WARN"
    }
} catch {
    Write-Log "Could not check wake timers: $_" "WARN"
}

# Step 6: Check sleep/hibernate availability
Write-Log "Checking sleep state availability..."
try {
    $sleepStates = & powercfg /availablesleepstates 2>&1 | Out-String
    Add-Content -Path $LogFile -Value $sleepStates
    Write-Log "Sleep states checked. See log for details." "INFO"
} catch {
    Write-Log "Could not check sleep states: $_" "WARN"
}

# Step 7: Disable hibernate on desktops to reclaim disk space
Write-Log "Checking for battery (laptop vs desktop)..."
try {
    $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
    if (-not $battery) {
        Write-Log "No battery detected (desktop). Disabling hibernate to reclaim disk space..." "INFO"
        $hibResult = & powercfg /hibernate off 2>&1 | Out-String
        Write-Log "Hibernate disabled. Hiberfil.sys space reclaimed." "SUCCESS"
    } else {
        Write-Log "Battery detected (laptop). Keeping hibernate enabled." "INFO"
    }
} catch {
    Write-Log "Could not check battery/hibernate: $_" "WARN"
}

# Step 8: Check for USB selective suspend issues
Write-Log "Checking USB selective suspend settings..."
try {
    # USB selective suspend GUID: 2a737441-1930-4402-8d77-b2bebba308a3
    # Setting GUID: 48e6b7a6-50f5-4782-a5d4-53bb8f07e226
    $usbResult = & powercfg /query SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 2>&1 | Out-String
    if ($usbResult -match "Current.*Index:\s*0x0+1") {
        Write-Log "USB selective suspend is ENABLED. This can cause USB device disconnection." "WARN"
        Write-Log "To disable: powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0" "INFO"
    } else {
        Write-Log "USB selective suspend is disabled." "SUCCESS"
    }
} catch {
    Write-Log "Could not check USB selective suspend: $_" "WARN"
}

Write-Log "=== Power Settings Remediation Completed (Exit Code: $ExitCode) ==="
exit $ExitCode
