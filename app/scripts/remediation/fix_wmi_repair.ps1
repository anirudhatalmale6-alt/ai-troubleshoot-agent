<#
.SYNOPSIS
    WMI Repository Repair Script
.DESCRIPTION
    Fixes Windows Management Instrumentation issues by:
    - Verifying WMI repository consistency
    - Attempting WMI repository salvage
    - Resetting WMI repository if needed
    - Re-registering WMI provider DLLs
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_wmi_repair.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_wmi_repair.log"
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

Write-Log "=== WMI Repository Repair Started ==="

# Step 1: Test basic WMI functionality
Write-Log "Testing basic WMI functionality..."
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    Write-Log "WMI basic query works: $($os.Caption) $($os.Version)" "SUCCESS"
} catch {
    Write-Log "WMI basic query FAILED: $_" "ERROR"
    $ExitCode = 1
}

# Step 2: Verify WMI repository consistency
Write-Log "Verifying WMI repository consistency (winmgmt /verifyrepository)..."
try {
    $verifyResult = & winmgmt /verifyrepository 2>&1 | Out-String
    Write-Log "Verify result: $($verifyResult.Trim())" "INFO"
    if ($verifyResult -match "consistent") {
        Write-Log "WMI repository is consistent." "SUCCESS"
    } else {
        Write-Log "WMI repository is NOT consistent. Will attempt salvage." "WARN"
        $ExitCode = 1
    }
} catch {
    Write-Log "Failed to verify WMI repository: $_" "ERROR"
    $ExitCode = 1
}

# Step 3: Attempt salvage if inconsistent
if ($ExitCode -ge 1) {
    Write-Log "Attempting WMI repository salvage (winmgmt /salvagerepository)..."
    try {
        $salvageResult = & winmgmt /salvagerepository 2>&1 | Out-String
        Write-Log "Salvage result: $($salvageResult.Trim())" "INFO"

        # Verify again after salvage
        $verifyAfter = & winmgmt /verifyrepository 2>&1 | Out-String
        if ($verifyAfter -match "consistent") {
            Write-Log "WMI repository is now consistent after salvage." "SUCCESS"
            $ExitCode = 0
        } else {
            Write-Log "Repository still inconsistent after salvage. Will attempt reset." "WARN"
        }
    } catch {
        Write-Log "Salvage failed: $_" "ERROR"
    }
}

# Step 4: Reset repository if salvage didn't work
if ($ExitCode -ge 1) {
    Write-Log "Attempting WMI repository reset (winmgmt /resetrepository)..." "WARN"
    Write-Log "WARNING: This will rebuild the WMI repository from scratch. Some third-party WMI providers may need reinstallation." "WARN"
    try {
        # Stop WMI service first
        Stop-Service -Name "Winmgmt" -Force -ErrorAction Stop
        Start-Sleep -Seconds 2

        $resetResult = & winmgmt /resetrepository 2>&1 | Out-String
        Write-Log "Reset result: $($resetResult.Trim())" "INFO"

        Start-Service -Name "Winmgmt" -ErrorAction Stop
        Start-Sleep -Seconds 3

        # Final verify
        $verifyFinal = & winmgmt /verifyrepository 2>&1 | Out-String
        if ($verifyFinal -match "consistent") {
            Write-Log "WMI repository rebuilt and consistent." "SUCCESS"
            $ExitCode = 0
        } else {
            Write-Log "WMI repository still inconsistent after reset." "ERROR"
            $ExitCode = 2
        }
    } catch {
        Write-Log "Repository reset failed: $_" "ERROR"
        $ExitCode = 2
        # Ensure WMI service is running
        Start-Service -Name "Winmgmt" -ErrorAction SilentlyContinue
    }
}

# Step 5: Re-register WMI DLLs and MOF files
Write-Log "Re-registering WMI core components..."
try {
    # Re-register core WMI DLLs
    $wmiDlls = @("scrcons.exe", "unsecapp.exe", "wmiadap.exe", "wmiapsrv.exe", "wmiprvse.exe")
    foreach ($dll in $wmiDlls) {
        $fullPath = "$env:SystemRoot\System32\wbem\$dll"
        if (Test-Path $fullPath) {
            & $fullPath /regserver 2>&1 | Out-Null
        }
    }
    Write-Log "WMI executables re-registered." "SUCCESS"

    # Re-compile MOF files
    Write-Log "Re-compiling WMI MOF files..."
    $mofPath = "$env:SystemRoot\System32\wbem"
    $mofFiles = Get-ChildItem -Path $mofPath -Filter "*.mof" -ErrorAction SilentlyContinue
    $mofSuccess = 0
    $mofFail = 0
    foreach ($mof in $mofFiles) {
        try {
            $result = & mofcomp $mof.FullName 2>&1 | Out-String
            if ($result -match "Error") { $mofFail++ } else { $mofSuccess++ }
        } catch {
            $mofFail++
        }
    }
    Write-Log "MOF compilation: $mofSuccess succeeded, $mofFail failed out of $($mofFiles.Count) files." $(if ($mofFail -eq 0) { "SUCCESS" } else { "WARN" })
} catch {
    Write-Log "Error re-registering WMI components: $_" "WARN"
}

# Step 6: Restart WMI and dependent services
Write-Log "Restarting WMI and dependent services..."
try {
    Restart-Service -Name "Winmgmt" -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    # Restart IP Helper (depends on WMI)
    Restart-Service -Name "iphlpsvc" -Force -ErrorAction SilentlyContinue
    Write-Log "WMI service restarted." "SUCCESS"
} catch {
    Write-Log "Failed to restart WMI service: $_" "ERROR"
    $ExitCode = 2
}

# Step 7: Final test
Write-Log "Running final WMI test..."
try {
    $testResult = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    Write-Log "WMI is working. Computer: $($testResult.Name), Domain: $($testResult.Domain)" "SUCCESS"
} catch {
    Write-Log "WMI is still not responding properly: $_" "ERROR"
    $ExitCode = 2
}

Write-Log "=== WMI Repository Repair Completed (Exit Code: $ExitCode) ==="
exit $ExitCode
