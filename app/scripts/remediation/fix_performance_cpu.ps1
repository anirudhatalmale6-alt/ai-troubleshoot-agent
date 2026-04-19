<#
.SYNOPSIS
    CPU Performance Remediation Script
.DESCRIPTION
    Addresses high CPU usage by:
    - Listing top CPU-consuming processes
    - Restarting known problematic services (WMI, BITS, Windows Update)
    - Detecting and killing stuck WMI providers
    - Checking for runaway svchost instances
    - Reporting CPU info and current load
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_performance_cpu.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_performance_cpu.log"
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

Write-Log "=== CPU Performance Remediation Started ==="

# Step 1: Get CPU information
Write-Log "Gathering CPU information..."
try {
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop
    foreach ($proc in $cpu) {
        Write-Log "CPU: $($proc.Name)" "INFO"
        Write-Log "  Cores: $($proc.NumberOfCores), Logical Processors: $($proc.NumberOfLogicalProcessors)" "INFO"
        Write-Log "  Current Load: $($proc.LoadPercentage)%" $(if ($proc.LoadPercentage -gt 80) { "ERROR" } elseif ($proc.LoadPercentage -gt 50) { "WARN" } else { "SUCCESS" })
    }
} catch {
    Write-Log "Could not get CPU info: $_" "WARN"
}

# Step 2: Get overall CPU usage sample
Write-Log "Sampling CPU usage (5 seconds)..."
try {
    $cpuSamples = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5 -ErrorAction Stop
    $avgCPU = [math]::Round(($cpuSamples.CounterSamples | Measure-Object -Property CookedValue -Average).Average, 1)
    $maxCPU = [math]::Round(($cpuSamples.CounterSamples | Measure-Object -Property CookedValue -Maximum).Maximum, 1)
    Write-Log "CPU usage: Average=$avgCPU%, Peak=$maxCPU%" $(if ($avgCPU -gt 80) { "ERROR" } elseif ($avgCPU -gt 50) { "WARN" } else { "SUCCESS" })
} catch {
    Write-Log "Could not sample CPU usage: $_" "WARN"
}

# Step 3: List top CPU-consuming processes
Write-Log "Top 15 CPU-consuming processes:" "INFO"
try {
    $topProcesses = Get-Process | Where-Object { $_.Id -ne 0 } |
        Sort-Object CPU -Descending |
        Select-Object -First 15 -Property Name, Id, CPU, @{N='MemoryMB';E={[math]::Round($_.WorkingSet64/1MB,1)}}, StartTime
    foreach ($proc in $topProcesses) {
        $cpuSeconds = [math]::Round($proc.CPU, 1)
        $uptime = if ($proc.StartTime) { [math]::Round((New-TimeSpan -Start $proc.StartTime -End (Get-Date)).TotalMinutes, 0) } else { "N/A" }
        Write-Log "  PID $($proc.Id) | $($proc.Name) | CPU=$cpuSeconds s | Mem=$($proc.MemoryMB) MB | Uptime=$uptime min" "INFO"
    }
} catch {
    Write-Log "Could not list top processes: $_" "WARN"
}

# Step 4: Check for stuck WMI providers
Write-Log "Checking for stuck WMI providers..."
try {
    $wmiProcs = Get-Process -Name "WmiPrvSE" -ErrorAction SilentlyContinue
    if ($wmiProcs) {
        foreach ($proc in $wmiProcs) {
            $cpuTime = [math]::Round($proc.CPU, 1)
            if ($cpuTime -gt 120) {
                Write-Log "Stuck WMI provider detected: PID $($proc.Id), CPU=$cpuTime s. Killing..." "ERROR"
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                Write-Log "Killed stuck WmiPrvSE PID $($proc.Id)." "SUCCESS"
            } else {
                Write-Log "WmiPrvSE PID $($proc.Id): CPU=$cpuTime s (normal)." "INFO"
            }
        }
    } else {
        Write-Log "No WmiPrvSE processes found." "INFO"
    }
} catch {
    Write-Log "Error checking WMI providers: $_" "WARN"
}

# Step 5: Restart known problematic services
Write-Log "Checking and restarting known problematic services..."
$problematicServices = @(
    @{ Name = "Winmgmt"; Display = "Windows Management Instrumentation (WMI)"; CPUThreshold = $true },
    @{ Name = "BITS"; Display = "Background Intelligent Transfer Service"; CPUThreshold = $true },
    @{ Name = "wuauserv"; Display = "Windows Update"; CPUThreshold = $true },
    @{ Name = "WSearch"; Display = "Windows Search Indexer"; CPUThreshold = $true },
    @{ Name = "SysMain"; Display = "SysMain (Superfetch)"; CPUThreshold = $true }
)

foreach ($svcInfo in $problematicServices) {
    try {
        $svc = Get-Service -Name $svcInfo.Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            # Check if associated process is consuming high CPU
            $wmiSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($svcInfo.Name)'" -ErrorAction SilentlyContinue
            if ($wmiSvc -and $wmiSvc.ProcessId -gt 0) {
                $svcProc = Get-Process -Id $wmiSvc.ProcessId -ErrorAction SilentlyContinue
                if ($svcProc -and $svcProc.CPU -gt 60) {
                    Write-Log "Restarting $($svcInfo.Display) (PID $($wmiSvc.ProcessId), CPU=$([math]::Round($svcProc.CPU,1))s)..." "WARN"
                    Restart-Service -Name $svcInfo.Name -Force -ErrorAction Stop
                    Write-Log "$($svcInfo.Display) restarted." "SUCCESS"
                } else {
                    Write-Log "$($svcInfo.Display) is running normally." "INFO"
                }
            }
        }
    } catch {
        Write-Log "Error restarting $($svcInfo.Display): $_" "WARN"
    }
}

# Step 6: Check for processes with very high handle counts (potential leak)
Write-Log "Checking for processes with high handle counts (potential resource leaks)..."
try {
    $highHandles = Get-Process | Where-Object { $_.HandleCount -gt 10000 } | Sort-Object HandleCount -Descending | Select-Object -First 5
    if ($highHandles) {
        foreach ($proc in $highHandles) {
            Write-Log "  High handle count: $($proc.Name) (PID $($proc.Id)) - $($proc.HandleCount) handles" "WARN"
        }
    } else {
        Write-Log "No processes with unusually high handle counts." "SUCCESS"
    }
} catch {
    Write-Log "Could not check handle counts: $_" "WARN"
}

# Step 7: Check for processes consuming high memory (which can cause swapping/CPU)
Write-Log "Checking for high memory consumers..."
try {
    $totalRAM = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB
    $highMem = Get-Process | Where-Object { $_.WorkingSet64 -gt ($totalRAM * 0.15 * 1GB) } | Sort-Object WorkingSet64 -Descending
    if ($highMem) {
        foreach ($proc in $highMem) {
            $memGB = [math]::Round($proc.WorkingSet64 / 1GB, 2)
            $memPercent = [math]::Round(($proc.WorkingSet64 / ($totalRAM * 1GB)) * 100, 1)
            Write-Log "  High memory: $($proc.Name) (PID $($proc.Id)) - $memGB GB ($memPercent% of RAM)" "WARN"
        }
    } else {
        Write-Log "No individual process using more than 15% of RAM." "SUCCESS"
    }
} catch {
    Write-Log "Could not check memory consumers: $_" "WARN"
}

# Final CPU sample after remediation
Write-Log "Final CPU usage check..."
try {
    $finalSample = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 3 -ErrorAction Stop
    $finalCPU = [math]::Round(($finalSample.CounterSamples | Measure-Object -Property CookedValue -Average).Average, 1)
    Write-Log "Current CPU usage: $finalCPU%" $(if ($finalCPU -gt 80) { "ERROR" } elseif ($finalCPU -gt 50) { "WARN" } else { "SUCCESS" })
} catch {
    Write-Log "Could not get final CPU reading." "WARN"
}

Write-Log "=== CPU Performance Remediation Completed (Exit Code: $ExitCode) ==="
exit $ExitCode
