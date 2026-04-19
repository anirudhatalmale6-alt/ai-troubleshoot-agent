<#
.SYNOPSIS
    Audio Service Remediation Script
.DESCRIPTION
    Fixes audio issues by:
    - Restarting Windows Audio and AudioEndpointBuilder services
    - Checking audio device status
    - Resetting audio drivers via disable/enable cycle
    - Verifying audio endpoints are active
    - Checking for recent audio error events
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_audio_service.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_audio_service.log"
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

Write-Log "=== Audio Service Remediation Started ==="

# Step 1: Restart AudioEndpointBuilder (must restart before Windows Audio)
Write-Log "Restarting AudioEndpointBuilder service..."
try {
    $aeb = Get-Service -Name "AudioEndpointBuilder" -ErrorAction Stop
    Write-Log "AudioEndpointBuilder current status: $($aeb.Status), StartType: $($aeb.StartType)" "INFO"

    if ($aeb.StartType -eq "Disabled") {
        Set-Service -Name "AudioEndpointBuilder" -StartupType Automatic -ErrorAction Stop
        Write-Log "AudioEndpointBuilder was Disabled. Set to Automatic." "SUCCESS"
    }

    if ($aeb.Status -eq "Running") {
        Restart-Service -Name "AudioEndpointBuilder" -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Log "AudioEndpointBuilder restarted." "SUCCESS"
    } else {
        Start-Service -Name "AudioEndpointBuilder" -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Log "AudioEndpointBuilder started." "SUCCESS"
    }
} catch {
    Write-Log "Failed to restart AudioEndpointBuilder: $_" "ERROR"
    $ExitCode = 1
}

# Step 2: Restart Windows Audio service
Write-Log "Restarting Windows Audio (Audiosrv) service..."
try {
    $audiosrv = Get-Service -Name "Audiosrv" -ErrorAction Stop
    Write-Log "Windows Audio current status: $($audiosrv.Status), StartType: $($audiosrv.StartType)" "INFO"

    if ($audiosrv.StartType -eq "Disabled") {
        Set-Service -Name "Audiosrv" -StartupType Automatic -ErrorAction Stop
        Write-Log "Windows Audio was Disabled. Set to Automatic." "SUCCESS"
    }

    if ($audiosrv.Status -eq "Running") {
        Restart-Service -Name "Audiosrv" -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Log "Windows Audio restarted." "SUCCESS"
    } else {
        Start-Service -Name "Audiosrv" -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Log "Windows Audio started." "SUCCESS"
    }
} catch {
    Write-Log "Failed to restart Windows Audio: $_" "ERROR"
    $ExitCode = 1
}

# Step 3: Check AudioDG process
Write-Log "Checking AudioDG process..."
try {
    $audiodg = Get-Process -Name "audiodg" -ErrorAction SilentlyContinue
    if ($audiodg) {
        Write-Log "AudioDG is running (PID: $($audiodg.Id), CPU: $([math]::Round($audiodg.CPU,1))s)." "SUCCESS"
        if ($audiodg.CPU -gt 60) {
            Write-Log "AudioDG is using high CPU. This may indicate an audio driver issue." "WARN"
        }
    } else {
        Write-Log "AudioDG process not found. Audio device may not be properly initialized." "WARN"
    }
} catch {
    Write-Log "Could not check AudioDG: $_" "WARN"
}

# Step 4: List audio devices and their status
Write-Log "Listing audio devices..."
try {
    $audioEndpoints = Get-PnpDevice -Class "AudioEndpoint" -ErrorAction SilentlyContinue
    if ($audioEndpoints) {
        foreach ($device in $audioEndpoints) {
            $statusLevel = if ($device.Status -eq "OK") { "SUCCESS" } elseif ($device.Status -eq "Error") { "ERROR" } else { "WARN" }
            Write-Log "  Audio Endpoint: $($device.FriendlyName) | Status: $($device.Status)" $statusLevel
        }
    } else {
        Write-Log "No audio endpoint devices found." "WARN"
    }

    $mediaDevices = Get-PnpDevice -Class "MEDIA" -ErrorAction SilentlyContinue
    if ($mediaDevices) {
        foreach ($device in $mediaDevices) {
            $statusLevel = if ($device.Status -eq "OK") { "SUCCESS" } elseif ($device.Status -eq "Error") { "ERROR" } else { "WARN" }
            Write-Log "  Media Device: $($device.FriendlyName) | Status: $($device.Status)" $statusLevel
        }
    }

    # Also check via WMI for broader compatibility
    $soundDevices = Get-CimInstance -ClassName Win32_SoundDevice -ErrorAction SilentlyContinue
    if ($soundDevices) {
        foreach ($sd in $soundDevices) {
            Write-Log "  Sound Device: $($sd.Name) | Status: $($sd.Status)" $(if ($sd.Status -eq "OK") { "SUCCESS" } else { "WARN" })
        }
    }
} catch {
    Write-Log "Could not list audio devices: $_" "WARN"
}

# Step 5: Reset audio drivers (disable/enable cycle)
Write-Log "Resetting audio drivers (disable/enable cycle)..."
try {
    $audioDrivers = Get-PnpDevice -Class "MEDIA" -Status "OK" -ErrorAction SilentlyContinue
    if ($audioDrivers) {
        foreach ($driver in $audioDrivers) {
            Write-Log "Resetting: $($driver.FriendlyName)..." "INFO"
            try {
                Disable-PnpDevice -InstanceId $driver.InstanceId -Confirm:$false -ErrorAction Stop
                Start-Sleep -Seconds 2
                Enable-PnpDevice -InstanceId $driver.InstanceId -Confirm:$false -ErrorAction Stop
                Start-Sleep -Seconds 2
                Write-Log "Reset audio driver: $($driver.FriendlyName)" "SUCCESS"
            } catch {
                Write-Log "Could not reset $($driver.FriendlyName): $_" "WARN"
            }
        }
    } else {
        # Try re-enabling errored devices
        $errorDevices = Get-PnpDevice -Class "MEDIA" -Status "Error" -ErrorAction SilentlyContinue
        if ($errorDevices) {
            foreach ($device in $errorDevices) {
                Write-Log "Attempting to re-enable errored device: $($device.FriendlyName)" "WARN"
                try {
                    Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction Stop
                    Write-Log "Re-enabled: $($device.FriendlyName)" "SUCCESS"
                } catch {
                    Write-Log "Failed to re-enable $($device.FriendlyName): $_" "ERROR"
                }
            }
        } else {
            Write-Log "No audio drivers found to reset." "WARN"
            $ExitCode = 1
        }
    }
} catch {
    Write-Log "Error resetting audio drivers: $_" "WARN"
}

# Step 6: Verify services are running after remediation
Write-Log "Verifying audio services final status..."
try {
    $finalAEB = Get-Service -Name "AudioEndpointBuilder" -ErrorAction Stop
    $finalAudio = Get-Service -Name "Audiosrv" -ErrorAction Stop

    Write-Log "AudioEndpointBuilder: $($finalAEB.Status)" $(if ($finalAEB.Status -eq "Running") { "SUCCESS" } else { "ERROR" })
    Write-Log "Windows Audio: $($finalAudio.Status)" $(if ($finalAudio.Status -eq "Running") { "SUCCESS" } else { "ERROR" })

    if ($finalAEB.Status -ne "Running" -or $finalAudio.Status -ne "Running") {
        $ExitCode = [Math]::Max($ExitCode, 1)
    }
} catch {
    Write-Log "Could not verify final service status: $_" "ERROR"
    $ExitCode = 2
}

# Step 7: Check recent audio error events
Write-Log "Checking recent audio error events..."
try {
    $audioEvents = Get-WinEvent -LogName "System" -FilterXPath "*[System[Provider[starts-with(@Name,'AudioSrv') or starts-with(@Name,'Microsoft-Windows-Audio')] and TimeCreated[timediff(@SystemTime) <= 604800000]]]" -MaxEvents 5 -ErrorAction SilentlyContinue
    if ($audioEvents) {
        Write-Log "Recent audio-related events:" "WARN"
        foreach ($evt in $audioEvents) {
            $msgPreview = $evt.Message.Substring(0, [Math]::Min(150, $evt.Message.Length))
            Write-Log "  EventID $($evt.Id) at $($evt.TimeCreated): $msgPreview" "WARN"
        }
    } else {
        Write-Log "No recent audio error events found." "SUCCESS"
    }
} catch {
    Write-Log "Could not query audio events: $_" "WARN"
}

Write-Log "=== Audio Service Remediation Completed (Exit Code: $ExitCode) ==="
Write-Log "If audio issues persist, try: msdt.exe /id AudioPlaybackDiagnostic" "INFO"
exit $ExitCode
