<#
.SYNOPSIS
    Service Restart Remediation Script
.DESCRIPTION
    Safely stops and restarts a Windows service by:
    - Accepting service name as a parameter
    - Checking service dependencies
    - Stopping the service (and dependents if needed)
    - Restarting the service and verifying status
.PARAMETER ServiceName
    The name of the Windows service to restart (e.g., "Spooler", "wuauserv")
.EXAMPLE
    .\fix_services_restart.ps1 -ServiceName "Spooler"
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_services_restart.log
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ServiceName
)

$LogFile = "$env:TEMP\TroubleshootAgent_fix_services_restart.log"
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

Write-Log "=== Service Restart Remediation Started for '$ServiceName' ==="

# Step 1: Validate service exists
Write-Log "Looking up service '$ServiceName'..."
try {
    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    Write-Log "Found service: $($service.DisplayName) (Name: $($service.Name), Status: $($service.Status), StartType: $($service.StartType))" "SUCCESS"
} catch {
    Write-Log "Service '$ServiceName' not found: $_" "ERROR"
    exit 2
}

# Step 2: Check for dependent services
Write-Log "Checking dependent services..."
$runningDependents = @()
try {
    $dependents = Get-Service -Name $ServiceName -DependentServices -ErrorAction SilentlyContinue
    $runningDependents = @($dependents | Where-Object { $_.Status -eq "Running" })
    if ($runningDependents.Count -gt 0) {
        Write-Log "Running dependent services that will also be stopped:" "WARN"
        foreach ($dep in $runningDependents) {
            Write-Log "  - $($dep.DisplayName) ($($dep.Name))" "WARN"
        }
    } else {
        Write-Log "No running dependent services." "INFO"
    }

    # Also show what this service depends on
    $dependencies = Get-Service -Name $ServiceName -RequiredServices -ErrorAction SilentlyContinue
    if ($dependencies) {
        Write-Log "This service depends on:" "INFO"
        foreach ($dep in $dependencies) {
            Write-Log "  - $($dep.DisplayName) ($($dep.Name)) [Status: $($dep.Status)]" "INFO"
        }
    }
} catch {
    Write-Log "Could not check dependencies: $_" "WARN"
}

# Step 3: Stop the service
if ($service.Status -eq "Running") {
    Write-Log "Stopping service '$($service.DisplayName)'..."
    try {
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        # Wait for stop with timeout
        $timeout = 30
        $elapsed = 0
        while ((Get-Service -Name $ServiceName).Status -ne "Stopped" -and $elapsed -lt $timeout) {
            Start-Sleep -Seconds 1
            $elapsed++
        }
        $service = Get-Service -Name $ServiceName
        if ($service.Status -eq "Stopped") {
            Write-Log "Service stopped successfully after $elapsed seconds." "SUCCESS"
        } else {
            Write-Log "Service did not stop within $timeout seconds (Status: $($service.Status))." "ERROR"
            # Try killing the process
            Write-Log "Attempting to kill the service process..." "WARN"
            try {
                $wmiSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
                if ($wmiSvc.ProcessId -gt 0) {
                    Stop-Process -Id $wmiSvc.ProcessId -Force -ErrorAction Stop
                    Start-Sleep -Seconds 2
                    Write-Log "Killed process PID $($wmiSvc.ProcessId)." "SUCCESS"
                }
            } catch {
                Write-Log "Could not kill service process: $_" "ERROR"
                $ExitCode = 2
            }
        }
    } catch {
        Write-Log "Failed to stop service: $_" "ERROR"
        $ExitCode = 1
    }
} elseif ($service.Status -eq "Stopped") {
    Write-Log "Service is already stopped." "INFO"
} else {
    Write-Log "Service is in state '$($service.Status)'. Attempting force stop..." "WARN"
    try {
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
    } catch {
        Write-Log "Force stop failed: $_" "WARN"
    }
}

# Step 4: Start the service
Write-Log "Starting service '$ServiceName'..."
try {
    # Ensure service is not disabled
    $service = Get-Service -Name $ServiceName
    if ($service.StartType -eq "Disabled") {
        Write-Log "Service is Disabled. Setting start type to Manual to allow start." "WARN"
        Set-Service -Name $ServiceName -StartupType Manual -ErrorAction Stop
    }

    Start-Service -Name $ServiceName -ErrorAction Stop
    # Wait for start with timeout
    $timeout = 30
    $elapsed = 0
    while ((Get-Service -Name $ServiceName).Status -ne "Running" -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 1
        $elapsed++
    }
    $service = Get-Service -Name $ServiceName
    if ($service.Status -eq "Running") {
        Write-Log "Service '$($service.DisplayName)' started successfully." "SUCCESS"
    } else {
        Write-Log "Service did not reach Running state within $timeout seconds (Status: $($service.Status))." "ERROR"
        $ExitCode = 1
    }
} catch {
    Write-Log "Failed to start service: $_" "ERROR"
    $ExitCode = 2
}

# Step 5: Restart dependent services that were running
if ($runningDependents.Count -gt 0) {
    Write-Log "Restarting dependent services..."
    foreach ($dep in $runningDependents) {
        try {
            Start-Service -Name $dep.Name -ErrorAction Stop
            Write-Log "Restarted dependent: $($dep.DisplayName)" "SUCCESS"
        } catch {
            Write-Log "Failed to restart dependent $($dep.DisplayName): $_" "WARN"
            $ExitCode = [Math]::Max($ExitCode, 1)
        }
    }
}

# Step 6: Final status
$finalService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
Write-Log "Final service status: $($finalService.DisplayName) = $($finalService.Status)" $(if ($finalService.Status -eq "Running") { "SUCCESS" } else { "ERROR" })

Write-Log "=== Service Restart Remediation Completed (Exit Code: $ExitCode) ==="
exit $ExitCode
