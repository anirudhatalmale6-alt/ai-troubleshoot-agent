# ============================================================
# Startup Optimization Script
# Lists startup programs and disables unnecessary ones
# ============================================================
$LogFile = "$env:TEMP\TroubleshootAgent_startup_optimize.log"
$ExitCode = 0

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $msg" | Tee-Object -FilePath $LogFile -Append
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Run as Administrator!" -ForegroundColor Red
    exit 2
}

Log "Starting startup optimization..."

try {
    # Step 1: List startup items from registry
    Write-Host "=== Registry Startup Items ===" -ForegroundColor Yellow
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    )

    foreach ($path in $regPaths) {
        if (Test-Path $path) {
            $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
            $props = $items.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }
            if ($props) {
                Write-Host "`n$path :" -ForegroundColor Cyan
                foreach ($prop in $props) {
                    Write-Host "  $($prop.Name) = $($prop.Value)" -ForegroundColor White
                    Log "Startup: $($prop.Name) at $path"
                }
            }
        }
    }

    # Step 2: List scheduled tasks at startup
    Write-Host "`n=== Scheduled Tasks (At Startup) ===" -ForegroundColor Yellow
    $tasks = Get-ScheduledTask | Where-Object { $_.Triggers | Where-Object { $_ -is [Microsoft.Management.Infrastructure.CimInstance] -and $_.CimClass.CimClassName -eq "MSFT_TaskBootTrigger" } } -ErrorAction SilentlyContinue
    if ($tasks) {
        foreach ($task in $tasks) {
            Write-Host "  $($task.TaskName) - $($task.State)" -ForegroundColor White
            Log "Boot task: $($task.TaskName)"
        }
    }

    # Step 3: List services set to auto-start
    Write-Host "`n=== Auto-Start Services ===" -ForegroundColor Yellow
    $autoServices = Get-Service | Where-Object { $_.StartType -eq "Automatic" -and $_.Status -ne "Running" }
    foreach ($svc in $autoServices) {
        Write-Host "  $($svc.Name) ($($svc.DisplayName)) - $($svc.Status)" -ForegroundColor Yellow
        Log "Auto-start not running: $($svc.Name)"
    }

    # Step 4: Clean temp files that slow boot
    Write-Host "`n=== Cleaning temp files ===" -ForegroundColor Yellow
    $tempPaths = @($env:TEMP, "$env:SystemRoot\Temp")
    foreach ($tp in $tempPaths) {
        if (Test-Path $tp) {
            $count = (Get-ChildItem $tp -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count
            Remove-Item "$tp\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Cleaned $count items from $tp" -ForegroundColor Green
            Log "Cleaned $count items from $tp"
        }
    }

    # Step 5: Prefetch cleanup
    $prefetch = "$env:SystemRoot\Prefetch"
    if (Test-Path $prefetch) {
        $count = (Get-ChildItem $prefetch -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($count -gt 200) {
            Remove-Item "$prefetch\*.pf" -Force -ErrorAction SilentlyContinue
            Write-Host "Cleaned $count prefetch files." -ForegroundColor Green
            Log "Cleaned $count prefetch files."
        }
    }

    Write-Host "`nStartup optimization complete." -ForegroundColor Green
    Log "Complete."
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Log "ERROR: $($_.Exception.Message)"
    $ExitCode = 2
}

exit $ExitCode
