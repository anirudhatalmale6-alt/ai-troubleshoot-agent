<#
.SYNOPSIS
    Windows Defender Reset Script
.DESCRIPTION
    Fixes Windows Defender/Security issues by:
    - Removing policies that may have disabled Defender
    - Updating virus/malware definitions
    - Restarting Windows Defender and Security Center services
    - Verifying real-time protection status
    - Running a quick scan
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_defender_reset.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_defender_reset.log"
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

Write-Log "=== Windows Defender Reset Started ==="

# Step 1: Remove GPO/registry policies that may disable Defender
Write-Log "Checking for policies that disable Defender..."
try {
    $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    if (Test-Path $policyPath) {
        # Check DisableAntiSpyware
        $disableAS = Get-ItemProperty -Path $policyPath -Name "DisableAntiSpyware" -ErrorAction SilentlyContinue
        if ($disableAS -and $disableAS.DisableAntiSpyware -eq 1) {
            Remove-ItemProperty -Path $policyPath -Name "DisableAntiSpyware" -Force -ErrorAction Stop
            Write-Log "Removed DisableAntiSpyware policy (was set to 1)." "SUCCESS"
        }

        # Check DisableAntiVirus
        $disableAV = Get-ItemProperty -Path $policyPath -Name "DisableAntiVirus" -ErrorAction SilentlyContinue
        if ($disableAV -and $disableAV.DisableAntiVirus -eq 1) {
            Remove-ItemProperty -Path $policyPath -Name "DisableAntiVirus" -Force -ErrorAction Stop
            Write-Log "Removed DisableAntiVirus policy." "SUCCESS"
        }

        # Check Real-Time Protection policies
        $rtpPath = "$policyPath\Real-Time Protection"
        if (Test-Path $rtpPath) {
            $disableRTP = Get-ItemProperty -Path $rtpPath -Name "DisableRealtimeMonitoring" -ErrorAction SilentlyContinue
            if ($disableRTP -and $disableRTP.DisableRealtimeMonitoring -eq 1) {
                Remove-ItemProperty -Path $rtpPath -Name "DisableRealtimeMonitoring" -Force -ErrorAction Stop
                Write-Log "Removed DisableRealtimeMonitoring policy." "SUCCESS"
            }
        }

        Write-Log "Policy check complete." "SUCCESS"
    } else {
        Write-Log "No Defender policy registry keys found." "INFO"
    }
} catch {
    Write-Log "Error removing policies: $_" "ERROR"
    $ExitCode = 1
}

# Step 2: Reset tamper protection state
Write-Log "Checking tamper protection..."
try {
    $tpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($tpStatus) {
        Write-Log "Tamper Protection: $($tpStatus.IsTamperProtected)" "INFO"
    }
} catch {
    Write-Log "Could not check tamper protection: $_" "WARN"
}

# Step 3: Restart security services
Write-Log "Restarting security services..."
$securityServices = @(
    @{ Name = "WinDefend"; Display = "Windows Defender Antivirus Service" },
    @{ Name = "wscsvc"; Display = "Security Center" },
    @{ Name = "SecurityHealthService"; Display = "Windows Security Service" },
    @{ Name = "WdNisSvc"; Display = "Windows Defender Network Inspection Service" }
)

foreach ($svcInfo in $securityServices) {
    try {
        $svc = Get-Service -Name $svcInfo.Name -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -ne "Running") {
                # Ensure not disabled
                if ($svc.StartType -eq "Disabled") {
                    Set-Service -Name $svcInfo.Name -StartupType Automatic -ErrorAction SilentlyContinue
                    Write-Log "Enabled $($svcInfo.Display) (was Disabled)." "SUCCESS"
                }
                Start-Service -Name $svcInfo.Name -ErrorAction Stop
                Write-Log "Started $($svcInfo.Display)." "SUCCESS"
            } else {
                # Restart running services (except WinDefend which may refuse restart)
                if ($svcInfo.Name -ne "WinDefend") {
                    Restart-Service -Name $svcInfo.Name -Force -ErrorAction SilentlyContinue
                    Write-Log "Restarted $($svcInfo.Display)." "SUCCESS"
                } else {
                    Write-Log "$($svcInfo.Display) is running." "SUCCESS"
                }
            }
        } else {
            Write-Log "$($svcInfo.Display) not found on this system." "WARN"
        }
    } catch {
        Write-Log "Failed to configure $($svcInfo.Display): $_" "WARN"
        $ExitCode = 1
    }
}

# Step 4: Update definitions
Write-Log "Updating Windows Defender definitions..."
try {
    $mpCmdPaths = @(
        "$env:ProgramFiles\Windows Defender\MpCmdRun.exe",
        "${env:ProgramFiles(x86)}\Windows Defender\MpCmdRun.exe"
    )
    $mpCmd = $null
    foreach ($path in $mpCmdPaths) {
        if (Test-Path $path) { $mpCmd = $path; break }
    }

    if ($mpCmd) {
        Write-Log "Running signature update via MpCmdRun.exe..."
        $updateResult = & $mpCmd -SignatureUpdate 2>&1 | Out-String
        Add-Content -Path $LogFile -Value $updateResult
        if ($updateResult -match "error" -or $LASTEXITCODE -ne 0) {
            Write-Log "Definition update may have encountered issues. Trying PowerShell cmdlet..." "WARN"
            Update-MpSignature -ErrorAction Stop
            Write-Log "Definitions updated via PowerShell." "SUCCESS"
        } else {
            Write-Log "Definitions updated successfully." "SUCCESS"
        }
    } else {
        Write-Log "MpCmdRun.exe not found. Trying PowerShell cmdlet..."
        Update-MpSignature -ErrorAction Stop
        Write-Log "Definitions updated via PowerShell." "SUCCESS"
    }
} catch {
    Write-Log "Failed to update definitions: $_" "WARN"
    $ExitCode = 1
}

# Step 5: Enable real-time protection if disabled
Write-Log "Verifying real-time protection..."
try {
    $mpPrefs = Get-MpPreference -ErrorAction Stop
    if ($mpPrefs.DisableRealtimeMonitoring -eq $true) {
        Write-Log "Real-time protection is DISABLED. Enabling..." "WARN"
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Write-Log "Real-time protection enabled." "SUCCESS"
    } else {
        Write-Log "Real-time protection is enabled." "SUCCESS"
    }
} catch {
    Write-Log "Could not verify/set real-time protection: $_" "WARN"
}

# Step 6: Check overall Defender status
Write-Log "Checking Defender status..."
try {
    $status = Get-MpComputerStatus -ErrorAction Stop
    Write-Log "  Antivirus Enabled: $($status.AntivirusEnabled)" $(if ($status.AntivirusEnabled) { "SUCCESS" } else { "ERROR" })
    Write-Log "  Real-Time Protection: $($status.RealTimeProtectionEnabled)" $(if ($status.RealTimeProtectionEnabled) { "SUCCESS" } else { "ERROR" })
    Write-Log "  Antispyware Enabled: $($status.AntispywareEnabled)" "INFO"
    Write-Log "  Definitions Version: $($status.AntivirusSignatureVersion)" "INFO"
    Write-Log "  Definitions Last Updated: $($status.AntivirusSignatureLastUpdated)" "INFO"
    Write-Log "  Full Scan Age (days): $($status.FullScanAge)" $(if ($status.FullScanAge -gt 30) { "WARN" } else { "INFO" })
    Write-Log "  Quick Scan Age (days): $($status.QuickScanAge)" $(if ($status.QuickScanAge -gt 7) { "WARN" } else { "INFO" })

    if (-not $status.AntivirusEnabled -or -not $status.RealTimeProtectionEnabled) {
        $ExitCode = [Math]::Max($ExitCode, 1)
    }
} catch {
    Write-Log "Could not get Defender status: $_" "ERROR"
    $ExitCode = 1
}

# Step 7: Trigger a quick scan
Write-Log "Starting a quick scan in the background..."
try {
    Start-MpScan -ScanType QuickScan -AsJob -ErrorAction Stop | Out-Null
    Write-Log "Quick scan initiated (running in background)." "SUCCESS"
} catch {
    Write-Log "Could not start quick scan: $_" "WARN"
}

Write-Log "=== Windows Defender Reset Completed (Exit Code: $ExitCode) ==="
exit $ExitCode
