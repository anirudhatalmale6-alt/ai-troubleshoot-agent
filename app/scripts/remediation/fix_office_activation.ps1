# ============================================================
# Office Activation Repair Script
# Resets Office activation, clears license cache
# ============================================================
$LogFile = "$env:TEMP\TroubleshootAgent_office_activation.log"
$ExitCode = 0

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $msg" | Tee-Object -FilePath $LogFile -Append
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Run as Administrator!" -ForegroundColor Red
    exit 2
}

Log "Starting Office activation repair..."

try {
    # Step 1: Close Office apps
    Write-Host "Closing Office applications..." -ForegroundColor Yellow
    $officeApps = @("WINWORD", "EXCEL", "POWERPNT", "OUTLOOK", "ONENOTE", "MSACCESS")
    foreach ($app in $officeApps) {
        Stop-Process -Name $app -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2

    # Step 2: Clear license cache
    Write-Host "Clearing license cache..." -ForegroundColor Yellow
    $licensePaths = @(
        "$env:LOCALAPPDATA\Microsoft\Office\Licenses",
        "$env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing"
    )
    foreach ($path in $licensePaths) {
        if (Test-Path $path) {
            Remove-Item -Path "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
            Log "Cleared: $path"
        }
    }

    # Step 3: Find ospp.vbs and run activation
    Write-Host "Looking for Office activation script..." -ForegroundColor Yellow
    $ospp = Get-ChildItem "C:\Program Files*\Microsoft Office" -Recurse -Filter "ospp.vbs" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ospp) {
        Write-Host "Running activation..." -ForegroundColor Yellow
        $result = cscript //nologo $ospp.FullName /act 2>&1
        Log "Activation result: $result"
        Write-Host $result -ForegroundColor Cyan
    } else {
        Write-Host "ospp.vbs not found. Office may use Click-to-Run licensing." -ForegroundColor Yellow
        Log "ospp.vbs not found."
        $ExitCode = 1
    }

    # Step 4: Clear credential manager Office entries
    Write-Host "Clearing cached Office credentials..." -ForegroundColor Yellow
    cmdkey /list 2>&1 | Select-String "MicrosoftOffice" | ForEach-Object {
        $target = ($_ -split "=")[1].Trim()
        cmdkey /delete:$target 2>&1 | Out-Null
        Log "Removed credential: $target"
    }

    Write-Host "Office activation repair complete. Restart an Office app to verify." -ForegroundColor Green
    Log "Repair complete."
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Log "ERROR: $($_.Exception.Message)"
    $ExitCode = 2
}

exit $ExitCode
