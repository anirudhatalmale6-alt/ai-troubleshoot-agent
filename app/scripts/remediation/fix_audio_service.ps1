# ============================================================
# Audio Service Fix Script
# Restarts Windows Audio and AudioEndpointBuilder services
# ============================================================
$LogFile = "$env:TEMP\TroubleshootAgent_audio_service.log"
$ExitCode = 0

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $msg" | Tee-Object -FilePath $LogFile -Append
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Run as Administrator!" -ForegroundColor Red
    exit 2
}

Log "Starting audio service fix..."

try {
    # Step 1: Restart audio services
    Write-Host "Restarting audio services..." -ForegroundColor Yellow
    $audioServices = @("AudioEndpointBuilder", "Audiosrv", "AudioSrv")

    foreach ($svc in $audioServices) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            Write-Host "  Restarting $($s.DisplayName)..." -ForegroundColor Yellow
            Restart-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            $s = Get-Service -Name $svc
            if ($s.Status -eq "Running") {
                Write-Host "  $($s.DisplayName): Running" -ForegroundColor Green
            } else {
                Write-Host "  $($s.DisplayName): $($s.Status)" -ForegroundColor Red
                $ExitCode = 1
            }
            Log "$($s.Name): $($s.Status)"
        }
    }

    # Step 2: Check audio devices
    Write-Host "`nAudio devices:" -ForegroundColor Yellow
    $audioDevices = Get-WmiObject Win32_SoundDevice -ErrorAction SilentlyContinue
    foreach ($device in $audioDevices) {
        $status = if ($device.Status -eq "OK") { "Green" } else { "Red" }
        Write-Host "  $($device.Name) - $($device.Status)" -ForegroundColor $status
        Log "Device: $($device.Name) - $($device.Status)"
    }

    # Step 3: Reset audio driver
    Write-Host "`nChecking for audio driver issues..." -ForegroundColor Yellow
    $audioHW = Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue
    if ($audioHW) {
        foreach ($dev in $audioHW) {
            Write-Host "  $($dev.FriendlyName) - $($dev.Status)" -ForegroundColor Cyan
            if ($dev.Status -ne "OK") {
                Write-Host "  Attempting to re-enable device..." -ForegroundColor Yellow
                Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                Log "Re-enabled: $($dev.FriendlyName)"
            }
        }
    }

    Write-Host "`nAudio service fix complete." -ForegroundColor Green
    Log "Complete."
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Log "ERROR: $($_.Exception.Message)"
    $ExitCode = 2
}

exit $ExitCode
