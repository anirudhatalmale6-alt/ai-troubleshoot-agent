# ============================================================
# AI Troubleshooting Agent — Windows Setup Script
# Run this as Administrator on your Windows Server 2019 VM
# ============================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  AI Troubleshooting Agent - Setup" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Check admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Run this script as Administrator!" -ForegroundColor Red
    exit 1
}

$installDir = "C:\TroubleshootAgent"

# Step 1: Install Python 3.11+
Write-Host "[1/5] Checking Python..." -ForegroundColor Yellow
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-Host "  Downloading Python 3.11..." -ForegroundColor Gray
    $pythonUrl = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
    $pythonInstaller = "$env:TEMP\python-installer.exe"
    Invoke-WebRequest -Uri $pythonUrl -OutFile $pythonInstaller
    Start-Process -Wait -FilePath $pythonInstaller -ArgumentList "/quiet", "InstallAllUsers=1", "PrependPath=1", "Include_pip=1"
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    Write-Host "  Python installed." -ForegroundColor Green
} else {
    Write-Host "  Python found: $($python.Source)" -ForegroundColor Green
}

# Step 2: Install Ollama
Write-Host "[2/5] Checking Ollama..." -ForegroundColor Yellow
$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollama) {
    Write-Host "  Downloading Ollama..." -ForegroundColor Gray
    $ollamaUrl = "https://ollama.com/download/OllamaSetup.exe"
    $ollamaInstaller = "$env:TEMP\OllamaSetup.exe"
    Invoke-WebRequest -Uri $ollamaUrl -OutFile $ollamaInstaller
    Start-Process -Wait -FilePath $ollamaInstaller -ArgumentList "/SILENT"
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    Write-Host "  Ollama installed." -ForegroundColor Green
} else {
    Write-Host "  Ollama found." -ForegroundColor Green
}

# Step 3: Pull LLM model
Write-Host "[3/5] Pulling llama3.1:8b model (this may take a while)..." -ForegroundColor Yellow
ollama pull llama3.1:8b
Write-Host "  Model ready." -ForegroundColor Green

# Step 4: Copy project files
Write-Host "[4/5] Setting up project..." -ForegroundColor Yellow
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

# Copy files (assumes script is run from the project directory)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Copy-Item -Path "$scriptDir\*" -Destination $installDir -Recurse -Force -Exclude ".git"
Write-Host "  Files copied to $installDir" -ForegroundColor Green

# Step 5: Install Python dependencies
Write-Host "[5/5] Installing Python dependencies..." -ForegroundColor Yellow
Set-Location $installDir
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
Write-Host "  Dependencies installed." -ForegroundColor Green

# Create .env from template
if (-not (Test-Path "$installDir\.env")) {
    Copy-Item "$installDir\.env.example" "$installDir\.env"
    Write-Host ""
    Write-Host "IMPORTANT: Edit $installDir\.env with your ServiceNow credentials" -ForegroundColor Yellow
}

# Create Windows service (optional)
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Setup Complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "To start the agent:" -ForegroundColor Cyan
Write-Host "  cd $installDir" -ForegroundColor White
Write-Host "  python main.py" -ForegroundColor White
Write-Host ""
Write-Host "API will be available at: http://localhost:8000" -ForegroundColor Cyan
Write-Host "API docs at: http://localhost:8000/docs" -ForegroundColor Cyan
Write-Host ""
Write-Host "To install as a Windows Service (auto-start):" -ForegroundColor Cyan
Write-Host "  python install_service.py install" -ForegroundColor White
Write-Host "  python install_service.py start" -ForegroundColor White
