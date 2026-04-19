<#
.SYNOPSIS
    Office Activation Repair Script
.DESCRIPTION
    Fixes Office activation issues by:
    - Closing all Office applications
    - Clearing Office license cache files
    - Running ospp.vbs /act to re-activate
    - Clearing cached Office credentials from Credential Manager
    - Checking Office activation status
.NOTES
    Requires Administrator privileges.
    Log file: $env:TEMP\TroubleshootAgent_fix_office_activation.log
#>

$LogFile = "$env:TEMP\TroubleshootAgent_fix_office_activation.log"
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

Write-Log "=== Office Activation Repair Started ==="

# Step 1: Close all Office applications
Write-Log "Closing Office applications..."
try {
    $officeApps = @("WINWORD", "EXCEL", "POWERPNT", "OUTLOOK", "ONENOTE", "MSACCESS", "MSPUB", "VISIO")
    $killed = 0
    foreach ($app in $officeApps) {
        $procs = Get-Process -Name $app -ErrorAction SilentlyContinue
        if ($procs) {
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            $killed += $procs.Count
        }
    }
    if ($killed -gt 0) {
        Start-Sleep -Seconds 3
        Write-Log "Terminated $killed Office process(es)." "SUCCESS"
    } else {
        Write-Log "No Office applications running." "INFO"
    }
} catch {
    Write-Log "Error closing Office apps: $_" "WARN"
}

# Step 2: Clear Office license cache
Write-Log "Clearing Office license cache..."
try {
    $licensePaths = @(
        "$env:LOCALAPPDATA\Microsoft\Office\Licenses",
        "$env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing",
        "$env:LOCALAPPDATA\Microsoft\Office\15.0\Licensing",
        "$env:PROGRAMDATA\Microsoft\Office\Licenses"
    )
    $cleared = 0
    foreach ($path in $licensePaths) {
        if (Test-Path $path) {
            $count = (Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue).Count
            Remove-Item -Path "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
            $cleared += $count
            Write-Log "Cleared $count item(s) from $path" "SUCCESS"
        }
    }
    if ($cleared -eq 0) {
        Write-Log "No license cache files found to clear." "INFO"
    }
} catch {
    Write-Log "Error clearing license cache: $_" "WARN"
    $ExitCode = 1
}

# Step 3: Clear Office identity cache (for Microsoft 365/O365)
Write-Log "Clearing Office identity cache..."
try {
    $identityPaths = @(
        "HKCU:\Software\Microsoft\Office\16.0\Common\Identity",
        "HKCU:\Software\Microsoft\Office\15.0\Common\Identity"
    )
    foreach ($regPath in $identityPaths) {
        if (Test-Path $regPath) {
            Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cleared identity cache at $regPath" "SUCCESS"
        }
    }
} catch {
    Write-Log "Error clearing identity cache: $_" "WARN"
}

# Step 4: Find and run ospp.vbs /act
Write-Log "Looking for Office activation script (ospp.vbs)..."
try {
    $osppPath = $null
    $searchPaths = @(
        "${env:ProgramFiles}\Microsoft Office\Office16\ospp.vbs",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office16\ospp.vbs",
        "${env:ProgramFiles}\Microsoft Office\root\Office16\ospp.vbs",
        "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\ospp.vbs",
        "${env:ProgramFiles}\Microsoft Office\Office15\ospp.vbs",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office15\ospp.vbs"
    )
    foreach ($path in $searchPaths) {
        if (Test-Path $path) { $osppPath = $path; break }
    }

    # Fallback: recursive search
    if (-not $osppPath) {
        $found = Get-ChildItem "C:\Program Files*\Microsoft Office" -Recurse -Filter "ospp.vbs" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $osppPath = $found.FullName }
    }

    if ($osppPath) {
        Write-Log "Found ospp.vbs at: $osppPath" "SUCCESS"

        # Check current activation status
        Write-Log "Checking current activation status..."
        $statusResult = & cscript //nologo $osppPath /dstatus 2>&1 | Out-String
        Add-Content -Path $LogFile -Value $statusResult
        Write-Log "Current status captured. See log for details." "INFO"

        # Run activation
        Write-Log "Running Office activation (ospp.vbs /act)..."
        $actResult = & cscript //nologo $osppPath /act 2>&1 | Out-String
        Add-Content -Path $LogFile -Value $actResult
        if ($actResult -match "Product activation successful" -or $actResult -match "ACTIVATED") {
            Write-Log "Office activation successful." "SUCCESS"
        } elseif ($actResult -match "ERROR" -or $actResult -match "0x") {
            Write-Log "Office activation encountered errors. Check log for details." "WARN"
            $ExitCode = 1
        } else {
            Write-Log "Activation command completed. Check log for details." "INFO"
        }
    } else {
        Write-Log "ospp.vbs not found. Office may use Click-to-Run (C2R) licensing instead." "WARN"

        # Try Click-to-Run repair
        Write-Log "Attempting Click-to-Run license repair..."
        $c2rPath = "${env:ProgramFiles}\Microsoft Office\Office16\ospprearm.exe"
        if (-not (Test-Path $c2rPath)) {
            $c2rPath = "${env:ProgramFiles}\Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe"
        }
        if (Test-Path $c2rPath) {
            Write-Log "Found C2R at: $c2rPath" "INFO"
        } else {
            Write-Log "Neither ospp.vbs nor C2R found. Manual Office repair may be needed." "WARN"
            $ExitCode = 1
        }
    }
} catch {
    Write-Log "Error during activation: $_" "ERROR"
    $ExitCode = 1
}

# Step 5: Clear cached Office credentials from Credential Manager
Write-Log "Clearing cached Office credentials from Credential Manager..."
try {
    $credList = & cmdkey /list 2>&1 | Out-String
    $officeCredsRemoved = 0
    $credList -split "`n" | Where-Object { $_ -match "Target:\s+(.*(MicrosoftOffice|office|mso).*)" } | ForEach-Object {
        if ($_ -match "Target:\s+(.+)$") {
            $target = $matches[1].Trim()
            & cmdkey /delete:"$target" 2>&1 | Out-Null
            Write-Log "Removed credential: $target" "SUCCESS"
            $officeCredsRemoved++
        }
    }
    if ($officeCredsRemoved -eq 0) {
        Write-Log "No Office-related credentials found in Credential Manager." "INFO"
    } else {
        Write-Log "Removed $officeCredsRemoved Office credential(s)." "SUCCESS"
    }
} catch {
    Write-Log "Error clearing credentials: $_" "WARN"
}

# Step 6: Reset Office shared computer activation token (if applicable)
Write-Log "Checking for shared computer activation tokens..."
try {
    $tokenPath = "$env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing\Token"
    if (Test-Path $tokenPath) {
        Remove-Item -Path "$tokenPath\*" -Force -ErrorAction SilentlyContinue
        Write-Log "Cleared shared activation tokens." "SUCCESS"
    }
} catch {
    Write-Log "Error clearing activation tokens: $_" "WARN"
}

Write-Log "=== Office Activation Repair Completed (Exit Code: $ExitCode) ==="
Write-Log "Restart any Office application to verify activation status." "INFO"
exit $ExitCode
