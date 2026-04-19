# ============================================================
# Outlook Repair Script
# Kills Outlook, clears OST cache, resets navigation pane
# ============================================================
$LogFile = "$env:TEMP\TroubleshootAgent_outlook_repair.log"
$ExitCode = 0

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $msg" | Tee-Object -FilePath $LogFile -Append
}

Log "Starting Outlook repair..."

try {
    # Step 1: Kill Outlook
    $outlook = Get-Process outlook -ErrorAction SilentlyContinue
    if ($outlook) {
        Write-Host "Closing Outlook..." -ForegroundColor Yellow
        Stop-Process -Name outlook -Force
        Start-Sleep -Seconds 3
        Log "Outlook process terminated."
    }

    # Step 2: Reset navigation pane
    Write-Host "Resetting navigation pane..." -ForegroundColor Yellow
    Start-Process "outlook.exe" -ArgumentList "/resetnavpane" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Stop-Process -Name outlook -Force -ErrorAction SilentlyContinue
    Log "Navigation pane reset."

    # Step 3: Find and rename corrupt OST files
    $localAppData = $env:LOCALAPPDATA
    $ostPath = Join-Path $localAppData "Microsoft\Outlook"
    if (Test-Path $ostPath) {
        $ostFiles = Get-ChildItem -Path $ostPath -Filter "*.ost" -ErrorAction SilentlyContinue
        foreach ($ost in $ostFiles) {
            $bakName = "$($ost.FullName).bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Write-Host "Backing up OST: $($ost.Name) -> $bakName" -ForegroundColor Yellow
            Rename-Item -Path $ost.FullName -NewName $bakName -ErrorAction SilentlyContinue
            Log "Renamed $($ost.Name) to backup."
        }
        Write-Host "OST files backed up. Outlook will recreate them on next launch." -ForegroundColor Green
    } else {
        Write-Host "No Outlook data folder found at $ostPath" -ForegroundColor Yellow
    }

    # Step 4: Find ScanPST
    Write-Host "Looking for Inbox Repair Tool (ScanPST)..." -ForegroundColor Yellow
    $scanpst = Get-ChildItem "C:\Program Files*\Microsoft Office" -Recurse -Filter "ScanPST.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($scanpst) {
        Write-Host "ScanPST found at: $($scanpst.FullName)" -ForegroundColor Green
        Write-Host "Run ScanPST manually on any PST files if corruption persists." -ForegroundColor Cyan
        Log "ScanPST location: $($scanpst.FullName)"
    } else {
        Write-Host "ScanPST not found. May need manual Office repair." -ForegroundColor Yellow
        $ExitCode = 1
    }

    Write-Host "Outlook repair complete. Launch Outlook to test." -ForegroundColor Green
    Log "Repair complete."
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Log "ERROR: $($_.Exception.Message)"
    $ExitCode = 2
}

exit $ExitCode
