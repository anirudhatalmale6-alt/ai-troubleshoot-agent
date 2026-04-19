# ============================================================
# CPU Performance Fix Script
# Lists top CPU consumers, restarts problematic services
# ============================================================
$LogFile = "$env:TEMP\TroubleshootAgent_performance_cpu.log"
$ExitCode = 0

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $msg" | Tee-Object -FilePath $LogFile -Append
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Run as Administrator!" -ForegroundColor Red
    exit 2
}

Log "Starting CPU performance analysis..."

try {
    # Step 1: Top CPU processes
    Write-Host "Top CPU-consuming processes:" -ForegroundColor Yellow
    $topProcesses = Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name, Id, CPU, WorkingSet64
    $topProcesses | Format-Table -AutoSize | Out-String | Write-Host -ForegroundColor Cyan
    Log "Top processes: $($topProcesses | ConvertTo-Json -Compress)"

    # Step 2: Check for known problematic services
    Write-Host "Checking known problematic services..." -ForegroundColor Yellow
    $services = @(
        @{Name="wuauserv"; Display="Windows Update"},
        @{Name="BITS"; Display="Background Intelligent Transfer"},
        @{Name="WMIApSrv"; Display="WMI Performance Adapter"},
        @{Name="WSearch"; Display="Windows Search"},
        @{Name="SysMain"; Display="SysMain/Superfetch"}
    )

    foreach ($svc in $services) {
        $s = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq "Running") {
            # Check if the service's process is using high CPU
            $proc = Get-Process -Name "svchost" -ErrorAction SilentlyContinue | Where-Object { $_.CPU -gt 60 }
            if ($proc) {
                Write-Host "Restarting $($svc.Display)..." -ForegroundColor Yellow
                Restart-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                Log "Restarted: $($svc.Name)"
            }
        }
    }

    # Step 3: Check for stuck WMI queries
    Write-Host "Checking for stuck WMI providers..." -ForegroundColor Yellow
    $wmiprvse = Get-Process -Name "WmiPrvSE" -ErrorAction SilentlyContinue
    if ($wmiprvse) {
        foreach ($proc in $wmiprvse) {
            if ($proc.CPU -gt 120) {
                Write-Host "Killing stuck WMI provider (PID $($proc.Id))..." -ForegroundColor Red
                Stop-Process -Id $proc.Id -Force
                Log "Killed stuck WmiPrvSE PID $($proc.Id)"
            }
        }
    }

    # Step 4: CPU info
    Write-Host "CPU Information:" -ForegroundColor Yellow
    $cpu = Get-WmiObject Win32_Processor | Select-Object Name, NumberOfCores, LoadPercentage
    Write-Host "  $($cpu.Name)" -ForegroundColor Cyan
    Write-Host "  Cores: $($cpu.NumberOfCores), Current Load: $($cpu.LoadPercentage)%" -ForegroundColor Cyan
    Log "CPU: $($cpu.Name), Load: $($cpu.LoadPercentage)%"

    Write-Host "CPU performance analysis complete." -ForegroundColor Green
    Log "Complete."
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Log "ERROR: $($_.Exception.Message)"
    $ExitCode = 2
}

exit $ExitCode
