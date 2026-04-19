<#
.SYNOPSIS
    Print Spooler Remediation Script
.DESCRIPTION
    Fixes print spooler issues by:
    - Stopping the Print Spooler service
    - Clearing the spool folder (stuck print jobs)
    - Restarting the Print Spooler service
    - Reporting on printer status
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_print_spooler.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_print_spooler.log"
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

Write-Log "=== Print Spooler Remediation Started ==="

# Step 1: Stop Print Spooler
Write-Log "Stopping Print Spooler service..."
try {
    $spooler = Get-Service -Name "Spooler" -ErrorAction Stop
    if ($spooler.Status -eq "Running") {
        Stop-Service -Name "Spooler" -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Log "Print Spooler stopped." "SUCCESS"
    } else {
        Write-Log "Print Spooler was not running (Status: $($spooler.Status))." "INFO"
    }
} catch {
    Write-Log "Failed to stop Print Spooler: $_" "ERROR"
    $ExitCode = 2
}

# Step 2: Clear spool folder
Write-Log "Clearing print spool folder..."
try {
    $spoolPath = "$env:SystemRoot\System32\spool\PRINTERS"
    if (Test-Path $spoolPath) {
        $files = Get-ChildItem -Path $spoolPath -Force -ErrorAction SilentlyContinue
        $count = $files.Count
        if ($count -gt 0) {
            Remove-Item "$spoolPath\*" -Force -Recurse -ErrorAction SilentlyContinue
            Write-Log "Cleared $count stuck job file(s) from spool folder." "SUCCESS"
        } else {
            Write-Log "Spool folder is already empty." "INFO"
        }
    } else {
        Write-Log "Spool folder not found at $spoolPath." "WARN"
    }
} catch {
    Write-Log "Error clearing spool folder: $_" "ERROR"
    $ExitCode = 1
}

# Step 3: Clear per-printer rendering folders
Write-Log "Clearing printer driver temp/rendering files..."
try {
    $driverPaths = @(
        "$env:SystemRoot\System32\spool\drivers\W32X86\3",
        "$env:SystemRoot\System32\spool\drivers\x64\3"
    )
    foreach ($driverPath in $driverPaths) {
        if (Test-Path $driverPath) {
            $tmpFiles = Get-ChildItem -Path $driverPath -Filter "*.tmp" -Force -ErrorAction SilentlyContinue
            if ($tmpFiles.Count -gt 0) {
                $tmpFiles | Remove-Item -Force -ErrorAction SilentlyContinue
                Write-Log "Cleared $($tmpFiles.Count) temp file(s) from $driverPath." "SUCCESS"
            }
        }
    }
} catch {
    Write-Log "Error clearing driver temp files: $_" "WARN"
}

# Step 4: Restart Print Spooler
Write-Log "Restarting Print Spooler service..."
try {
    Start-Service -Name "Spooler" -ErrorAction Stop
    Start-Sleep -Seconds 2
    $spooler = Get-Service -Name "Spooler" -ErrorAction Stop
    if ($spooler.Status -eq "Running") {
        Write-Log "Print Spooler restarted successfully." "SUCCESS"
    } else {
        Write-Log "Print Spooler status: $($spooler.Status)" "WARN"
        $ExitCode = 1
    }
} catch {
    Write-Log "Failed to restart Print Spooler: $_" "ERROR"
    $ExitCode = 2
}

# Step 5: List installed printers
Write-Log "Listing installed printers..."
try {
    $printers = Get-Printer -ErrorAction SilentlyContinue
    if ($printers) {
        foreach ($p in $printers) {
            $status = if ($p.PrinterStatus -eq 0) { "Normal" } else { $p.PrinterStatus }
            Write-Log "  Printer: $($p.Name) | Port: $($p.PortName) | Status: $status | Shared: $($p.Shared)" "INFO"
        }
    } else {
        Write-Log "No printers found." "INFO"
    }
} catch {
    Write-Log "Could not list printers: $_" "WARN"
}

# Step 6: Check for stuck print jobs
Write-Log "Checking for remaining print jobs..."
try {
    $jobs = Get-PrintJob -PrinterName (Get-Printer | Select-Object -ExpandProperty Name) -ErrorAction SilentlyContinue
    if ($jobs) {
        Write-Log "Found $($jobs.Count) print job(s) still in queue:" "WARN"
        foreach ($job in $jobs) {
            Write-Log "  Job $($job.Id): $($job.DocumentName) - Status: $($job.JobStatus)" "WARN"
            try {
                Remove-PrintJob -InputObject $job -ErrorAction Stop
                Write-Log "  Removed stuck job $($job.Id)." "SUCCESS"
            } catch {
                Write-Log "  Could not remove job $($job.Id): $_" "WARN"
            }
        }
    } else {
        Write-Log "No stuck print jobs found." "SUCCESS"
    }
} catch {
    Write-Log "Could not check print jobs: $_" "WARN"
}

Write-Log "=== Print Spooler Remediation Completed (Exit Code: $ExitCode) ==="
exit $ExitCode
