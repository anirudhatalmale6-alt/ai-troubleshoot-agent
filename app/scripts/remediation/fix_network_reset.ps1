<#
.SYNOPSIS
    Network Reset Remediation Script
.DESCRIPTION
    Resets network configuration by:
    - Flushing DNS cache
    - Resetting Winsock catalog
    - Resetting TCP/IP stack
    - Releasing and renewing DHCP leases
    - Resetting Windows Firewall to defaults
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_network_reset.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_network_reset.log"
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

Write-Log "=== Network Reset Remediation Started ==="

# Step 1: Flush DNS cache
Write-Log "Flushing DNS resolver cache..."
try {
    $result = & ipconfig /flushdns 2>&1 | Out-String
    Write-Log "DNS cache flushed: $($result.Trim())" "SUCCESS"
} catch {
    Write-Log "Failed to flush DNS: $_" "ERROR"
    $ExitCode = 1
}

# Step 2: Reset Winsock catalog
Write-Log "Resetting Winsock catalog..."
try {
    $result = & netsh winsock reset 2>&1 | Out-String
    Write-Log "Winsock reset: $($result.Trim())" "SUCCESS"
} catch {
    Write-Log "Failed to reset Winsock: $_" "ERROR"
    $ExitCode = 1
}

# Step 3: Reset TCP/IP stack
Write-Log "Resetting TCP/IP stack..."
try {
    $result = & netsh int ip reset 2>&1 | Out-String
    Write-Log "TCP/IP reset completed." "SUCCESS"
    Add-Content -Path $LogFile -Value $result
} catch {
    Write-Log "Failed to reset TCP/IP: $_" "ERROR"
    $ExitCode = 1
}

# Step 4: Reset IPv6
Write-Log "Resetting IPv6 stack..."
try {
    $result = & netsh int ipv6 reset 2>&1 | Out-String
    Write-Log "IPv6 reset completed." "SUCCESS"
} catch {
    Write-Log "Failed to reset IPv6: $_" "WARN"
}

# Step 5: Release and renew DHCP
Write-Log "Releasing DHCP leases..."
try {
    $result = & ipconfig /release 2>&1 | Out-String
    Write-Log "DHCP released." "SUCCESS"
} catch {
    Write-Log "DHCP release failed (may not have DHCP adapters): $_" "WARN"
}

Write-Log "Renewing DHCP leases..."
try {
    $result = & ipconfig /renew 2>&1 | Out-String
    Write-Log "DHCP renewed." "SUCCESS"
} catch {
    Write-Log "DHCP renew failed: $_" "WARN"
    $ExitCode = 1
}

# Step 6: Clear ARP cache
Write-Log "Clearing ARP cache..."
try {
    $result = & netsh interface ip delete arpcache 2>&1 | Out-String
    Write-Log "ARP cache cleared." "SUCCESS"
} catch {
    Write-Log "Failed to clear ARP cache: $_" "WARN"
}

# Step 7: Reset Windows Firewall to defaults
Write-Log "Resetting Windows Firewall to default rules..."
try {
    $result = & netsh advfirewall reset 2>&1 | Out-String
    Write-Log "Firewall reset to defaults: $($result.Trim())" "SUCCESS"
} catch {
    Write-Log "Failed to reset firewall: $_" "ERROR"
    $ExitCode = 1
}

# Step 8: Verify connectivity
Write-Log "Verifying network connectivity..."
try {
    $ping = Test-Connection -ComputerName "8.8.8.8" -Count 2 -ErrorAction Stop
    $avgMs = [math]::Round(($ping | Measure-Object -Property Latency -Average).Average, 1)
    Write-Log "Network connectivity OK. Average latency to 8.8.8.8: $avgMs ms" "SUCCESS"
} catch {
    Write-Log "No network connectivity detected after reset. A reboot may be required." "WARN"
    $ExitCode = 1
}

# Step 9: Display current IP configuration
Write-Log "Current IP configuration:" "INFO"
try {
    $adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne "127.0.0.1" }
    foreach ($adapter in $adapters) {
        Write-Log "  Interface: $($adapter.InterfaceAlias) | IP: $($adapter.IPAddress)/$($adapter.PrefixLength)" "INFO"
    }
} catch {
    Write-Log "Could not retrieve IP configuration." "WARN"
}

Write-Log "=== Network Reset Remediation Completed (Exit Code: $ExitCode) ==="
Write-Log "A reboot is recommended to complete all network stack resets." "WARN"
exit $ExitCode
