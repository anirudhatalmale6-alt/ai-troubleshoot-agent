<#
.SYNOPSIS
    Outlook Repair Remediation Script
.DESCRIPTION
    Fixes common Outlook issues by:
    - Killing Outlook processes
    - Clearing OST cache files (renamed to .old for safety)
    - Locating and launching ScanPST (Inbox Repair Tool)
    - Resetting the Outlook navigation pane
    - Clearing Outlook temp/RoamCache files
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_outlook_repair.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_outlook_repair.log"
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

Write-Log "=== Outlook Repair Remediation Started ==="

# Step 1: Kill Outlook processes
Write-Log "Stopping Outlook processes..."
try {
    $outlookProcs = Get-Process -Name "OUTLOOK" -ErrorAction SilentlyContinue
    if ($outlookProcs) {
        $outlookProcs | Stop-Process -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
        Write-Log "Outlook processes terminated ($($outlookProcs.Count) instance(s))." "SUCCESS"
    } else {
        Write-Log "No Outlook processes running." "INFO"
    }
} catch {
    Write-Log "Failed to kill Outlook: $_" "ERROR"
    $ExitCode = 1
}

# Step 2: Find and rename OST files (safer than deleting)
Write-Log "Searching for OST cache files..."
try {
    $outlookDataPaths = @(
        "$env:LOCALAPPDATA\Microsoft\Outlook",
        "$env:APPDATA\Microsoft\Outlook"
    )
    $ostFiles = @()
    foreach ($path in $outlookDataPaths) {
        if (Test-Path $path) {
            $found = Get-ChildItem -Path $path -Filter "*.ost" -Recurse -ErrorAction SilentlyContinue
            $ostFiles += $found
        }
    }

    if ($ostFiles.Count -gt 0) {
        foreach ($ost in $ostFiles) {
            $sizeMB = [math]::Round($ost.Length / 1MB, 2)
            Write-Log "Found OST: $($ost.FullName) ($sizeMB MB)" "INFO"
            try {
                $backupName = "$($ost.FullName).old_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                Rename-Item -Path $ost.FullName -NewName $backupName -Force -ErrorAction Stop
                Write-Log "Renamed OST to backup. Outlook will rebuild cache on next launch." "SUCCESS"
            } catch {
                Write-Log "Could not rename OST (may be locked): $_" "WARN"
                $ExitCode = 1
            }
        }
    } else {
        Write-Log "No OST files found." "INFO"
    }
} catch {
    Write-Log "Error searching for OST files: $_" "WARN"
}

# Step 3: Find and launch ScanPST
Write-Log "Searching for ScanPST (Inbox Repair Tool)..."
try {
    $scanPstPath = $null
    $searchPaths = @(
        "${env:ProgramFiles}\Microsoft Office\root\Office16\SCANPST.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\SCANPST.EXE",
        "${env:ProgramFiles}\Microsoft Office\root\Office15\SCANPST.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\root\Office15\SCANPST.EXE",
        "${env:ProgramFiles}\Microsoft Office\Office16\SCANPST.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office16\SCANPST.EXE"
    )
    foreach ($path in $searchPaths) {
        if (Test-Path $path) { $scanPstPath = $path; break }
    }

    # Fallback: recursive search
    if (-not $scanPstPath) {
        $found = Get-ChildItem "C:\Program Files*\Microsoft Office" -Recurse -Filter "ScanPST.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $scanPstPath = $found.FullName }
    }

    if ($scanPstPath) {
        Write-Log "Found ScanPST at: $scanPstPath" "SUCCESS"

        # Find PST files
        $pstFiles = @()
        foreach ($path in $outlookDataPaths) {
            if (Test-Path $path) {
                $found = Get-ChildItem -Path $path -Filter "*.pst" -Recurse -ErrorAction SilentlyContinue
                $pstFiles += $found
            }
        }
        if ($pstFiles.Count -gt 0) {
            foreach ($pst in $pstFiles) {
                Write-Log "Launching ScanPST for: $($pst.FullName)" "INFO"
                try {
                    Start-Process -FilePath $scanPstPath -ArgumentList "`"$($pst.FullName)`"" -ErrorAction Stop
                    Write-Log "ScanPST launched. User must click 'Start' then 'Repair' in the GUI." "SUCCESS"
                } catch {
                    Write-Log "Failed to launch ScanPST: $_" "WARN"
                }
            }
        } else {
            Write-Log "No PST files found to scan." "INFO"
        }
    } else {
        Write-Log "ScanPST.exe not found. Office may not be installed or uses a different path." "WARN"
    }
} catch {
    Write-Log "Error finding ScanPST: $_" "WARN"
}

# Step 4: Reset Outlook navigation pane
Write-Log "Resetting Outlook navigation pane..."
try {
    $outlookExe = $null
    $exePaths = @(
        "${env:ProgramFiles}\Microsoft Office\root\Office16\OUTLOOK.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\OUTLOOK.EXE",
        "${env:ProgramFiles}\Microsoft Office\root\Office15\OUTLOOK.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\root\Office15\OUTLOOK.EXE"
    )
    foreach ($path in $exePaths) {
        if (Test-Path $path) { $outlookExe = $path; break }
    }

    if ($outlookExe) {
        $proc = Start-Process -FilePath $outlookExe -ArgumentList "/resetnavpane" -Wait -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2
        Stop-Process -Name "OUTLOOK" -Force -ErrorAction SilentlyContinue
        Write-Log "Outlook navigation pane reset." "SUCCESS"
    } else {
        # Try from PATH
        Start-Process "outlook.exe" -ArgumentList "/resetnavpane" -Wait -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Stop-Process -Name "OUTLOOK" -Force -ErrorAction SilentlyContinue
        Write-Log "Attempted nav pane reset via PATH." "INFO"
    }
} catch {
    Write-Log "Could not reset navigation pane: $_" "WARN"
}

# Step 5: Clear Outlook temp and RoamCache files
Write-Log "Clearing Outlook temporary files..."
try {
    $roamCache = "$env:LOCALAPPDATA\Microsoft\Outlook\RoamCache"
    if (Test-Path $roamCache) {
        $count = (Get-ChildItem -Path $roamCache -Force -ErrorAction SilentlyContinue).Count
        Remove-Item "$roamCache\*" -Force -Recurse -ErrorAction SilentlyContinue
        Write-Log "Cleared $count item(s) from Outlook RoamCache." "SUCCESS"
    }

    # Clear secure temp folder
    $secTempReg = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Office\16.0\Outlook\Security" -Name "OutlookSecureTempFolder" -ErrorAction SilentlyContinue
    if ($secTempReg) {
        $secTemp = $secTempReg.OutlookSecureTempFolder
        if (Test-Path $secTemp) {
            $count = (Get-ChildItem -Path $secTemp -Force -ErrorAction SilentlyContinue).Count
            Remove-Item "$secTemp\*" -Force -ErrorAction SilentlyContinue
            Write-Log "Cleared $count item(s) from Outlook secure temp folder." "SUCCESS"
        }
    }
} catch {
    Write-Log "Error clearing Outlook temp files: $_" "WARN"
}

# Step 6: Clear AutoComplete cache (NK2/Stream file)
Write-Log "Clearing AutoComplete cache..."
try {
    $streamPath = "$env:LOCALAPPDATA\Microsoft\Outlook\RoamCache"
    if (Test-Path $streamPath) {
        $streamFiles = Get-ChildItem -Path $streamPath -Filter "Stream_Autocomplete*" -ErrorAction SilentlyContinue
        if ($streamFiles) {
            foreach ($f in $streamFiles) {
                $backupName = "$($f.FullName).bak"
                Rename-Item -Path $f.FullName -NewName $backupName -Force -ErrorAction SilentlyContinue
            }
            Write-Log "AutoComplete cache backed up ($($streamFiles.Count) file(s))." "SUCCESS"
        }
    }
} catch {
    Write-Log "Error clearing AutoComplete: $_" "WARN"
}

Write-Log "=== Outlook Repair Remediation Completed (Exit Code: $ExitCode) ==="
Write-Log "Outlook will rebuild its OST cache on next launch (this may take some time for large mailboxes)." "INFO"
exit $ExitCode
