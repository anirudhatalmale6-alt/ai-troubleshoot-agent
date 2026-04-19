<#
.SYNOPSIS
    VPN L2TP/IPsec Remediation Script
.DESCRIPTION
    Fixes common L2TP VPN connection issues by:
    - Setting AssumeUDPEncapsulationContextOnSendRule registry key
    - Restarting IPsec-related services
    - Verifying VPN adapter configuration
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_vpn_l2tp.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_vpn_l2tp.log"
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

Write-Log "=== VPN L2TP Remediation Started ==="

# Step 1: Set AssumeUDPEncapsulationContextOnSendRule registry key
# This is the most common fix for L2TP behind NAT
Write-Log "Setting AssumeUDPEncapsulationContextOnSendRule registry key..."
try {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\PolicyAgent"
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    $currentValue = Get-ItemProperty -Path $regPath -Name "AssumeUDPEncapsulationContextOnSendRule" -ErrorAction SilentlyContinue
    if ($currentValue -and $currentValue.AssumeUDPEncapsulationContextOnSendRule -eq 2) {
        Write-Log "AssumeUDPEncapsulationContextOnSendRule is already set to 2." "INFO"
    } else {
        Set-ItemProperty -Path $regPath -Name "AssumeUDPEncapsulationContextOnSendRule" -Value 2 -Type DWord -Force
        Write-Log "AssumeUDPEncapsulationContextOnSendRule set to 2 (server and client behind NAT)." "SUCCESS"
    }
} catch {
    Write-Log "Failed to set registry key: $_" "ERROR"
    $ExitCode = 2
}

# Step 2: Ensure IPsec related services are configured correctly
Write-Log "Configuring IPsec services..."
$ipsecServices = @(
    @{ Name = "PolicyAgent"; DisplayName = "IPsec Policy Agent" },
    @{ Name = "IKEEXT"; DisplayName = "IKE and AuthIP IPsec Keying Modules" },
    @{ Name = "RasMan"; DisplayName = "Remote Access Connection Manager" },
    @{ Name = "SstpSvc"; DisplayName = "Secure Socket Tunneling Protocol Service" }
)

foreach ($svcInfo in $ipsecServices) {
    try {
        $svc = Get-Service -Name $svcInfo.Name -ErrorAction SilentlyContinue
        if ($svc) {
            # Ensure service is set to automatic or demand start
            if ($svc.StartType -eq "Disabled") {
                Set-Service -Name $svcInfo.Name -StartupType Automatic -ErrorAction Stop
                Write-Log "Enabled $($svcInfo.DisplayName) (was Disabled)." "SUCCESS"
            }
            # Restart the service
            if ($svc.Status -eq "Running") {
                Restart-Service -Name $svcInfo.Name -Force -ErrorAction Stop
                Write-Log "Restarted $($svcInfo.DisplayName)." "SUCCESS"
            } else {
                Start-Service -Name $svcInfo.Name -ErrorAction Stop
                Write-Log "Started $($svcInfo.DisplayName)." "SUCCESS"
            }
        } else {
            Write-Log "$($svcInfo.DisplayName) service not found." "WARN"
        }
    } catch {
        Write-Log "Failed to configure $($svcInfo.DisplayName): $_" "WARN"
        $ExitCode = 1
    }
}

# Step 3: Ensure L2TP ports are not blocked
Write-Log "Checking L2TP/IPsec firewall rules..."
try {
    # Check if UDP 500 and 4500 are allowed
    $rules = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
        $_.Enabled -eq $true -and $_.Direction -eq "Outbound"
    }
    Write-Log "Ensuring UDP ports 500 and 4500 are not blocked..." "INFO"

    # Create allow rules if they don't exist
    $ruleName500 = "L2TP-IPsec-UDP500"
    $ruleName4500 = "L2TP-IPsec-UDP4500"

    $existing500 = Get-NetFirewallRule -DisplayName $ruleName500 -ErrorAction SilentlyContinue
    if (-not $existing500) {
        New-NetFirewallRule -DisplayName $ruleName500 -Direction Outbound -Protocol UDP -RemotePort 500 -Action Allow -ErrorAction Stop | Out-Null
        Write-Log "Created firewall rule allowing outbound UDP 500." "SUCCESS"
    } else {
        Write-Log "Firewall rule for UDP 500 already exists." "INFO"
    }

    $existing4500 = Get-NetFirewallRule -DisplayName $ruleName4500 -ErrorAction SilentlyContinue
    if (-not $existing4500) {
        New-NetFirewallRule -DisplayName $ruleName4500 -Direction Outbound -Protocol UDP -RemotePort 4500 -Action Allow -ErrorAction Stop | Out-Null
        Write-Log "Created firewall rule allowing outbound UDP 4500." "SUCCESS"
    } else {
        Write-Log "Firewall rule for UDP 4500 already exists." "INFO"
    }
} catch {
    Write-Log "Firewall rule check/creation failed: $_" "WARN"
}

# Step 4: Verify ProhibitIPSec registry (should NOT be set for L2TP/IPsec)
Write-Log "Checking ProhibitIPSec registry key..."
try {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\RasMan\Parameters"
    $prohibit = Get-ItemProperty -Path $regPath -Name "ProhibitIPSec" -ErrorAction SilentlyContinue
    if ($prohibit -and $prohibit.ProhibitIPSec -eq 1) {
        Write-Log "ProhibitIPSec is set to 1. This may block L2TP/IPsec. Removing..." "WARN"
        Remove-ItemProperty -Path $regPath -Name "ProhibitIPSec" -Force -ErrorAction Stop
        Write-Log "ProhibitIPSec removed." "SUCCESS"
    } else {
        Write-Log "ProhibitIPSec is not set (good)." "SUCCESS"
    }
} catch {
    Write-Log "Could not check ProhibitIPSec: $_" "WARN"
}

# Step 5: List existing VPN connections
Write-Log "Listing configured VPN connections..."
try {
    $vpnConns = Get-VpnConnection -ErrorAction SilentlyContinue
    if ($vpnConns) {
        foreach ($vpn in $vpnConns) {
            Write-Log "  VPN: $($vpn.Name) | Type: $($vpn.TunnelType) | Server: $($vpn.ServerAddress) | Status: $($vpn.ConnectionStatus)" "INFO"
        }
    } else {
        Write-Log "No VPN connections configured." "INFO"
    }
} catch {
    Write-Log "Could not list VPN connections: $_" "WARN"
}

Write-Log "=== VPN L2TP Remediation Completed (Exit Code: $ExitCode) ==="
Write-Log "A reboot is required for the registry changes to take full effect." "WARN"
exit $ExitCode
