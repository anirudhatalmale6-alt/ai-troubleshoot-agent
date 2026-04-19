<#
.SYNOPSIS
    Startup Optimization Script
.DESCRIPTION
    Optimizes Windows startup by:
    - Listing all startup programs (registry Run keys, startup folder, scheduled tasks)
    - Identifying and optionally disabling unnecessary startup items
    - Cleaning Run/RunOnce registry keys of invalid entries
    - Reporting auto-start services that failed to start
    - Cleaning temp files that slow boot
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_startup_optimize.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_startup_optimize.log"
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

Write-Log "=== Startup Optimization Started ==="

# Known unnecessary startup programs (safe to disable)
$unnecessaryStartup = @(
    "iTunesHelper", "Spotify", "Steam", "Discord", "Skype",
    "OneDrive", "GoogleUpdate", "AdobeAAMUpdater", "AdobeGCInvoker",
    "CCleaner", "CyberLink", "QuickTime", "RealPlayer",
    "Cortana", "GameBar", "XboxGamingOverlay", "BingDesktop",
    "Dropbox", "GlassWire", "NordVPN", "ExpressVPN"
)

# Step 1: List startup items from registry Run keys
Write-Log "=== Registry Startup Items ===" "INFO"
$regPaths = @(
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; Scope = "Machine" },
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; Scope = "User" },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"; Scope = "Machine-Once" },
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"; Scope = "User-Once" },
    @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Scope = "Machine-32bit" }
)

$totalStartupItems = 0
foreach ($regInfo in $regPaths) {
    try {
        if (Test-Path $regInfo.Path) {
            $items = Get-ItemProperty -Path $regInfo.Path -ErrorAction SilentlyContinue
            $props = $items.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }
            if ($props) {
                Write-Log "[$($regInfo.Scope)] $($regInfo.Path):" "INFO"
                foreach ($prop in $props) {
                    $totalStartupItems++
                    $isUnnecessary = $unnecessaryStartup | Where-Object { $prop.Name -match $_ -or $prop.Value -match $_ }

                    # Check if the target executable exists
                    $exePath = $prop.Value -replace '"', '' -replace '\s+/.*$', '' -replace '\s+-.*$', ''
                    $exists = Test-Path $exePath -ErrorAction SilentlyContinue

                    if ($isUnnecessary) {
                        Write-Log "  [DISABLE?] $($prop.Name) = $($prop.Value)" "WARN"
                    } elseif (-not $exists -and $exePath -match '\\') {
                        Write-Log "  [INVALID]  $($prop.Name) = $($prop.Value) (target not found)" "ERROR"
                    } else {
                        Write-Log "  [OK]       $($prop.Name) = $($prop.Value)" "INFO"
                    }
                }
            }
        }
    } catch {
        Write-Log "Error reading $($regInfo.Path): $_" "WARN"
    }
}
Write-Log "Total registry startup items: $totalStartupItems" "INFO"

# Step 2: Clean invalid RunOnce entries
Write-Log "Cleaning invalid RunOnce entries..."
try {
    $runOncePaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
    )
    $cleaned = 0
    foreach ($path in $runOncePaths) {
        if (Test-Path $path) {
            $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
            $props = $items.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }
            foreach ($prop in $props) {
                $exePath = $prop.Value -replace '"', '' -replace '\s+/.*$', ''
                if ($exePath -match '\\' -and -not (Test-Path $exePath -ErrorAction SilentlyContinue)) {
                    Remove-ItemProperty -Path $path -Name $prop.Name -Force -ErrorAction SilentlyContinue
                    Write-Log "Removed invalid RunOnce entry: $($prop.Name)" "SUCCESS"
                    $cleaned++
                }
            }
        }
    }
    Write-Log "Cleaned $cleaned invalid RunOnce entries." "SUCCESS"
} catch {
    Write-Log "Error cleaning RunOnce: $_" "WARN"
}

# Step 3: List startup folder items
Write-Log "=== Startup Folder Items ===" "INFO"
try {
    $startupFolders = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
        "$env:PROGRAMDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    )
    foreach ($folder in $startupFolders) {
        if (Test-Path $folder) {
            $items = Get-ChildItem -Path $folder -ErrorAction SilentlyContinue
            if ($items) {
                Write-Log "Folder: $folder" "INFO"
                foreach ($item in $items) {
                    Write-Log "  $($item.Name)" "INFO"
                    $totalStartupItems++
                }
            }
        }
    }
} catch {
    Write-Log "Error reading startup folders: $_" "WARN"
}

# Step 4: List scheduled tasks set to run at boot/logon
Write-Log "=== Scheduled Tasks (Boot/Logon) ===" "INFO"
try {
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.State -ne "Disabled" -and
        ($_.Triggers | Where-Object {
            $_.CimClass.CimClassName -eq "MSFT_TaskBootTrigger" -or
            $_.CimClass.CimClassName -eq "MSFT_TaskLogonTrigger"
        })
    }
    if ($tasks) {
        foreach ($task in $tasks | Select-Object -First 20) {
            Write-Log "  $($task.TaskName) | Path: $($task.TaskPath) | State: $($task.State)" "INFO"
        }
        Write-Log "Found $($tasks.Count) boot/logon scheduled tasks." "INFO"
    } else {
        Write-Log "No boot/logon scheduled tasks found." "INFO"
    }
} catch {
    Write-Log "Error listing scheduled tasks: $_" "WARN"
}

# Step 5: Check auto-start services that failed to start
Write-Log "=== Auto-Start Services Not Running ===" "INFO"
try {
    $failedAuto = Get-Service | Where-Object {
        $_.StartType -eq "Automatic" -and $_.Status -ne "Running"
    }
    if ($failedAuto) {
        Write-Log "Auto-start services not currently running:" "WARN"
        foreach ($svc in $failedAuto) {
            Write-Log "  $($svc.Name) ($($svc.DisplayName)) - Status: $($svc.Status)" "WARN"
        }
    } else {
        Write-Log "All auto-start services are running." "SUCCESS"
    }
} catch {
    Write-Log "Error checking auto-start services: $_" "WARN"
}

# Step 6: Clean temp files that slow boot
Write-Log "Cleaning temp files that may slow boot..."
try {
    $tempPaths = @($env:TEMP, "$env:SystemRoot\Temp")
    $totalCleaned = 0
    foreach ($tp in $tempPaths) {
        if (Test-Path $tp) {
            $items = Get-ChildItem -Path $tp -Recurse -Force -ErrorAction SilentlyContinue
            $count = $items.Count
            $items | ForEach-Object {
                try { Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop; $totalCleaned++ } catch {}
            }
            Write-Log "Cleaned from $tp : $totalCleaned of $count items" "SUCCESS"
        }
    }
} catch {
    Write-Log "Error cleaning temp files: $_" "WARN"
}

# Step 7: Check boot time
Write-Log "Checking last boot time..."
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $bootTime = $os.LastBootUpTime
    $uptime = (New-TimeSpan -Start $bootTime -End (Get-Date))
    Write-Log "Last boot: $bootTime (uptime: $([math]::Round($uptime.TotalHours, 1)) hours)" "INFO"
} catch {
    Write-Log "Could not determine boot time: $_" "WARN"
}

Write-Log "=== Startup Optimization Completed (Exit Code: $ExitCode) ==="
exit $ExitCode
