# ============================================================
# Windows Defender Reset Script
# Resets Defender policies, updates definitions, restarts services
# ============================================================
$LogFile = "$env:TEMP\TroubleshootAgent_defender_reset.log"
$ExitCode = 0

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $msg" | Tee-Object -FilePath $LogFile -Append
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Run as Administrator!" -ForegroundColor Red
    exit 2
}

Log "Starting Windows Defender reset..."

try {
    # Step 1: Remove policy that may disable Defender
    Write-Host "Checking for policies disabling Defender..." -ForegroundColor Yellow
    $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    if (Test-Path $policyPath) {
        $disableAV = Get-ItemProperty -Path $policyPath -Name "DisableAntiSpyware" -ErrorAction SilentlyContinue
        if ($disableAV -and $disableAV.DisableAntiSpyware -eq 1) {
            Remove-ItemProperty -Path $policyPath -Name "DisableAntiSpyware" -Force -ErrorAction SilentlyContinue
            Write-Host "Removed DisableAntiSpyware policy." -ForegroundColor Green
            Log "Removed DisableAntiSpyware policy."
        }
    }

    # Step 2: Restart security services
    Write-Host "Restarting security services..." -ForegroundColor Yellow
    $services = @("WinDefend", "wscsvc", "SecurityHealthService")
    foreach ($svc in $services) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            if ($s.Status -ne "Running") {
                Start-Service -Name $svc -ErrorAction SilentlyContinue
                Write-Host "  Started $svc" -ForegroundColor Green
            } else {
                Restart-Service -Name $svc -Force -ErrorAction SilentlyContinue
                Write-Host "  Restarted $svc" -ForegroundColor Green
            }
            Log "Service $svc restarted."
        }
    }

    # Step 3: Update definitions
    Write-Host "Updating Defender definitions..." -ForegroundColor Yellow
    $mpCmd = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
    if (Test-Path $mpCmd) {
        & $mpCmd -SignatureUpdate 2>&1 | Out-Null
        Write-Host "Definitions updated." -ForegroundColor Green
        Log "Definitions updated."
    } else {
        Write-Host "MpCmdRun.exe not found." -ForegroundColor Yellow
        $ExitCode = 1
    }

    # Step 4: Check Defender status
    Write-Host "Checking Defender status..." -ForegroundColor Yellow
    $status = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($status) {
        Write-Host "  Antivirus Enabled: $($status.AntivirusEnabled)" -ForegroundColor Cyan
        Write-Host "  Real-time Protection: $($status.RealTimeProtectionEnabled)" -ForegroundColor Cyan
        Write-Host "  Definitions Version: $($status.AntivirusSignatureVersion)" -ForegroundColor Cyan
        Write-Host "  Last Updated: $($status.AntivirusSignatureLastUpdated)" -ForegroundColor Cyan
        Log "Status: AV=$($status.AntivirusEnabled), RTP=$($status.RealTimeProtectionEnabled)"
    }

    Write-Host "Defender reset complete." -ForegroundColor Green
    Log "Complete."
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Log "ERROR: $($_.Exception.Message)"
    $ExitCode = 2
}

exit $ExitCode
