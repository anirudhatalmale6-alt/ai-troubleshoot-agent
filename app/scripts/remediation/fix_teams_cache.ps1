# ============================================================
# Microsoft Teams Cache Cleanup Script
# Kills Teams, clears cache folders, optionally restarts Teams
# ============================================================
$LogFile = "$env:TEMP\TroubleshootAgent_teams_cache.log"
$ExitCode = 0

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $msg" | Tee-Object -FilePath $LogFile -Append
}

Log "Starting Teams cache cleanup..."

try {
    # Step 1: Kill Teams
    Write-Host "Closing Microsoft Teams..." -ForegroundColor Yellow
    Stop-Process -Name "Teams" -Force -ErrorAction SilentlyContinue
    Stop-Process -Name "ms-teams" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Log "Teams processes terminated."

    # Step 2: Clear Teams cache (Classic Teams)
    $teamsClassic = "$env:APPDATA\Microsoft\Teams"
    if (Test-Path $teamsClassic) {
        Write-Host "Clearing Classic Teams cache..." -ForegroundColor Yellow
        $cacheFolders = @("Cache", "blob_storage", "databases", "GPUCache", "IndexedDB", "Local Storage", "tmp")
        foreach ($folder in $cacheFolders) {
            $path = Join-Path $teamsClassic $folder
            if (Test-Path $path) {
                Remove-Item -Path "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
                Log "Cleared: $path"
            }
        }
        Write-Host "Classic Teams cache cleared." -ForegroundColor Green
    }

    # Step 3: Clear New Teams cache
    $teamsNew = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams"
    if (Test-Path $teamsNew) {
        Write-Host "Clearing New Teams cache..." -ForegroundColor Yellow
        Remove-Item -Path "$teamsNew\*" -Recurse -Force -ErrorAction SilentlyContinue
        Log "Cleared New Teams cache."
        Write-Host "New Teams cache cleared." -ForegroundColor Green
    }

    # Step 4: Clear Credential Manager entries for Teams
    Write-Host "Clearing Teams credentials..." -ForegroundColor Yellow
    cmdkey /list 2>&1 | Select-String "teams" | ForEach-Object {
        $target = ($_ -split "=")[1].Trim()
        cmdkey /delete:$target 2>&1 | Out-Null
        Log "Removed credential: $target"
    }

    Write-Host "Teams cache cleanup complete. Please restart Teams." -ForegroundColor Green
    Log "Cleanup complete."
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Log "ERROR: $($_.Exception.Message)"
    $ExitCode = 2
}

exit $ExitCode
