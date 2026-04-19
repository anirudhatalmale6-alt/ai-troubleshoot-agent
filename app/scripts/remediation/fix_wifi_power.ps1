<#
.SYNOPSIS
    WiFi Power Management Remediation Script
.DESCRIPTION
    Fixes WiFi connectivity issues caused by power management by:
    - Disabling power management on WiFi adapters
    - Resetting WLAN AutoConfig service
    - Setting WiFi adapter to maximum performance
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_wifi_power.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_wifi_power.log"
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

Write-Log "=== WiFi Power Management Remediation Started ==="

# Step 1: Find WiFi adapters and disable power management
Write-Log "Disabling power management on WiFi adapters..."
try {
    # Get wireless network adapters via CIM
    $wifiAdapters = Get-NetAdapter | Where-Object {
        $_.InterfaceDescription -match "Wi-Fi|Wireless|802\.11|WLAN" -or $_.Name -match "Wi-Fi|Wireless"
    }

    if ($wifiAdapters) {
        foreach ($adapter in $wifiAdapters) {
            Write-Log "Found WiFi adapter: $($adapter.Name) ($($adapter.InterfaceDescription))" "INFO"

            # Disable power management via WMI/CIM
            try {
                $pnpDevice = Get-CimInstance -ClassName MSPower_DeviceWakeEnable -Namespace root\wmi -ErrorAction SilentlyContinue |
                    Where-Object { $_.InstanceName -match ($adapter.InterfaceDescription -replace '[^\w]', '.') }

                # Use PnP device properties to disable power saving
                $pnpEntityName = $adapter.InterfaceDescription
                $device = Get-PnpDevice | Where-Object { $_.FriendlyName -eq $pnpEntityName } -ErrorAction SilentlyContinue

                if ($device) {
                    # Disable "Allow the computer to turn off this device to save power"
                    $powerMgmt = Get-CimInstance -ClassName Win32_NetworkAdapter |
                        Where-Object { $_.Name -eq $adapter.InterfaceDescription }
                    if ($powerMgmt) {
                        # Registry-based approach for power management
                        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002bE10318}"
                        $subkeys = Get-ChildItem $regPath -ErrorAction SilentlyContinue
                        foreach ($key in $subkeys) {
                            $driverDesc = Get-ItemProperty -Path $key.PSPath -Name "DriverDesc" -ErrorAction SilentlyContinue
                            if ($driverDesc -and $driverDesc.DriverDesc -eq $adapter.InterfaceDescription) {
                                # PnPCapabilities: 0x18 = disable power management
                                Set-ItemProperty -Path $key.PSPath -Name "PnPCapabilities" -Value 24 -Type DWord -Force -ErrorAction Stop
                                Write-Log "Disabled power management for $($adapter.Name) via registry." "SUCCESS"
                                break
                            }
                        }
                    }
                }
            } catch {
                Write-Log "Could not disable power management via registry for $($adapter.Name): $_" "WARN"
            }

            # Set adapter power saving mode to maximum performance
            try {
                $powerSaving = Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction SilentlyContinue
                if ($powerSaving) {
                    Set-NetAdapterPowerManagement -Name $adapter.Name -WakeOnMagicPacket Disabled -WakeOnPattern Disabled -ErrorAction SilentlyContinue
                    Write-Log "Disabled wake-on features for $($adapter.Name)." "SUCCESS"
                }
            } catch {
                Write-Log "Could not modify NetAdapterPowerManagement for $($adapter.Name): $_" "WARN"
            }
        }
    } else {
        Write-Log "No WiFi adapters found." "WARN"
        $ExitCode = 1
    }
} catch {
    Write-Log "Error finding WiFi adapters: $_" "ERROR"
    $ExitCode = 1
}

# Step 2: Set WiFi power mode to maximum performance in power plan
Write-Log "Setting wireless adapter power mode to Maximum Performance..."
try {
    # Wireless Adapter Settings > Power Saving Mode GUID
    # GUID: 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 (power saving mode)
    # Sub GUID: 12bbebe6-58d6-4636-95bb-3217ef867c1a (wireless adapter settings)
    $result = & powercfg /setacvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>&1
    $result2 = & powercfg /setdcvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>&1
    & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
    Write-Log "Wireless adapter power mode set to Maximum Performance (AC and DC)." "SUCCESS"
} catch {
    Write-Log "Failed to set power plan wireless settings: $_" "WARN"
}

# Step 3: Reset WLAN AutoConfig service
Write-Log "Restarting WLAN AutoConfig service..."
try {
    $wlanSvc = Get-Service -Name "WlanSvc" -ErrorAction Stop
    if ($wlanSvc.StartType -eq "Disabled") {
        Set-Service -Name "WlanSvc" -StartupType Automatic -ErrorAction Stop
        Write-Log "WLAN AutoConfig was disabled. Set to Automatic." "SUCCESS"
    }
    Restart-Service -Name "WlanSvc" -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    $wlanSvc = Get-Service -Name "WlanSvc"
    Write-Log "WLAN AutoConfig restarted (Status: $($wlanSvc.Status))." "SUCCESS"
} catch {
    Write-Log "Failed to restart WLAN AutoConfig: $_" "ERROR"
    $ExitCode = 1
}

# Step 4: Show current WiFi connection info
Write-Log "Current WiFi connection status:" "INFO"
try {
    $wlanInfo = & netsh wlan show interfaces 2>&1 | Out-String
    Add-Content -Path $LogFile -Value $wlanInfo
    if ($wlanInfo -match "State\s+:\s+connected") {
        Write-Log "WiFi is currently connected." "SUCCESS"
    } elseif ($wlanInfo -match "State\s+:\s+disconnected") {
        Write-Log "WiFi is currently disconnected." "WARN"
    } else {
        Write-Log "WiFi state could not be determined." "INFO"
    }
} catch {
    Write-Log "Could not query WiFi status: $_" "WARN"
}

Write-Log "=== WiFi Power Management Remediation Completed (Exit Code: $ExitCode) ==="
Write-Log "A reboot may be needed for registry-based power management changes." "WARN"
exit $ExitCode
