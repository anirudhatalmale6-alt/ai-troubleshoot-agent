<#
.SYNOPSIS
    Microsoft Teams Cache Cleanup Script
.DESCRIPTION
    Fixes Teams performance and loading issues by:
    - Killing all Teams processes
    - Clearing Classic Teams cache folders
    - Clearing New Teams (MSIX) cache folders
    - Clearing Teams credentials from Credential Manager
    - Restarting Teams
.NOTES
    Does not require Administrator privileges (runs in user context).
    Log file: $env:TEMP\TroubleshootAgent_fix_teams_cache.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_teams_cache.log"
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

# Admin check is optional for Teams cache cleanup but recommended
if (-not (Test-Admin)) {
    Write-Log "Running without Administrator privileges. Some operations may be limited." "WARN"
}

Write-Log "=== Teams Cache Cleanup Started ==="

# Step 1: Kill all Teams processes
Write-Log "Stopping Microsoft Teams processes..."
try {
    $teamsNames = @("Teams", "ms-teams", "MSTeams")
    $killed = 0
    foreach ($name in $teamsNames) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($procs) {
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            $killed += $procs.Count
        }
    }
    if ($killed -gt 0) {
        Start-Sleep -Seconds 3
        Write-Log "Terminated $killed Teams process(es)." "SUCCESS"
    } else {
        Write-Log "No Teams processes running." "INFO"
    }
} catch {
    Write-Log "Error killing Teams processes: $_" "WARN"
}

# Step 2: Clear Classic Teams cache
$totalCleared = 0
Write-Log "Checking for Classic Teams cache..."
try {
    $teamsClassicPath = "$env:APPDATA\Microsoft\Teams"
    if (Test-Path $teamsClassicPath) {
        $cacheFolders = @(
            "Cache", "blob_storage", "databases", "GPUCache",
            "IndexedDB", "Local Storage", "Session Storage",
            "tmp", "Code Cache", "Service Worker"
        )
        foreach ($folder in $cacheFolders) {
            $folderPath = Join-Path $teamsClassicPath $folder
            if (Test-Path $folderPath) {
                $count = (Get-ChildItem -Path $folderPath -Recurse -Force -ErrorAction SilentlyContinue).Count
                Remove-Item -Path "$folderPath\*" -Recurse -Force -ErrorAction SilentlyContinue
                $totalCleared += $count
                Write-Log "Cleared $count item(s) from Classic Teams/$folder" "SUCCESS"
            }
        }

        # Also clear the cookies and storage files
        $filesToClear = @("Cookies", "Cookies-journal", "storage.json", "Network Persistent State")
        foreach ($file in $filesToClear) {
            $filePath = Join-Path $teamsClassicPath $file
            if (Test-Path $filePath) {
                Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
                $totalCleared++
            }
        }

        Write-Log "Classic Teams cache cleanup complete." "SUCCESS"
    } else {
        Write-Log "Classic Teams folder not found (may be using New Teams)." "INFO"
    }
} catch {
    Write-Log "Error clearing Classic Teams cache: $_" "WARN"
    $ExitCode = 1
}

# Step 3: Clear New Teams (MSIX/Store) cache
Write-Log "Checking for New Teams cache..."
try {
    $newTeamsPaths = @(
        "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams",
        "$env:LOCALAPPDATA\Packages\MicrosoftTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams"
    )
    foreach ($newTeamsPath in $newTeamsPaths) {
        if (Test-Path $newTeamsPath) {
            $count = (Get-ChildItem -Path $newTeamsPath -Recurse -Force -ErrorAction SilentlyContinue).Count
            Remove-Item -Path "$newTeamsPath\*" -Recurse -Force -ErrorAction SilentlyContinue
            $totalCleared += $count
            Write-Log "Cleared $count item(s) from New Teams cache." "SUCCESS"
        }
    }

    # Also check WebView2 cache for New Teams
    $webView2Path = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Local\Microsoft\Teams\EBWebView"
    if (Test-Path $webView2Path) {
        $count = (Get-ChildItem -Path $webView2Path -Recurse -Force -ErrorAction SilentlyContinue).Count
        Remove-Item -Path "$webView2Path\*" -Recurse -Force -ErrorAction SilentlyContinue
        $totalCleared += $count
        Write-Log "Cleared $count item(s) from Teams WebView2 cache." "SUCCESS"
    }
} catch {
    Write-Log "Error clearing New Teams cache: $_" "WARN"
}

Write-Log "Total items cleared: $totalCleared" "INFO"

# Step 4: Clear Teams credentials from Credential Manager
Write-Log "Clearing Teams credentials from Credential Manager..."
try {
    $credList = & cmdkey /list 2>&1 | Out-String
    $teamsCredsRemoved = 0
    $credList -split "`n" | Where-Object { $_ -match "Target:\s+(.*(teams|skype).*)" } | ForEach-Object {
        if ($_ -match "Target:\s+(.+)$") {
            $target = $matches[1].Trim()
            & cmdkey /delete:"$target" 2>&1 | Out-Null
            Write-Log "Removed credential: $target" "SUCCESS"
            $teamsCredsRemoved++
        }
    }
    if ($teamsCredsRemoved -eq 0) {
        Write-Log "No Teams-related credentials found in Credential Manager." "INFO"
    }
} catch {
    Write-Log "Error clearing credentials: $_" "WARN"
}

# Step 5: Clear Teams logs
Write-Log "Clearing Teams log files..."
try {
    $logPaths = @(
        "$env:APPDATA\Microsoft\Teams\logs.txt",
        "$env:APPDATA\Microsoft\Teams\old_logs*"
    )
    foreach ($logPath in $logPaths) {
        if (Test-Path $logPath) {
            Remove-Item -Path $logPath -Force -ErrorAction SilentlyContinue
            Write-Log "Cleared log: $logPath" "SUCCESS"
        }
    }
} catch {
    Write-Log "Error clearing logs: $_" "WARN"
}

# Step 6: Restart Teams
Write-Log "Attempting to restart Microsoft Teams..."
try {
    # Try New Teams first
    $newTeamsExe = "$env:LOCALAPPDATA\Microsoft\Teams\current\Teams.exe"
    $msTeamsExe = (Get-Command "ms-teams" -ErrorAction SilentlyContinue).Source
    $storeTeams = Get-AppxPackage -Name "MSTeams" -ErrorAction SilentlyContinue

    if ($storeTeams) {
        Start-Process "shell:AppsFolder\MSTeams_8wekyb3d8bbwe!MSTeams" -ErrorAction SilentlyContinue
        Write-Log "New Teams (Store) launched." "SUCCESS"
    } elseif (Test-Path $newTeamsExe) {
        Start-Process $newTeamsExe -ErrorAction SilentlyContinue
        Write-Log "Teams launched from $newTeamsExe." "SUCCESS"
    } else {
        Write-Log "Could not auto-launch Teams. Please start it manually." "WARN"
    }
} catch {
    Write-Log "Could not restart Teams: $_" "WARN"
    Write-Log "Please start Teams manually." "INFO"
}

Write-Log "=== Teams Cache Cleanup Completed (Exit Code: $ExitCode) ==="
exit $ExitCode
