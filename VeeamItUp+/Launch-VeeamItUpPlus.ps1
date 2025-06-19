# Veeam Backup Explorer Launcher
# This script launches the main application

Write-Host "🚀 Launching Veeam Backup Explorer..." -ForegroundColor Cyan
Write-Host ""

# Get the script directory
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$mainApp = Join-Path $scriptPath "src\VeeamItUpPlus.ps1"

# Check if the main application exists
if (Test-Path $mainApp) {
    Write-Host "✅ Starting application..." -ForegroundColor Green
    & $mainApp
} else {
    Write-Host "❌ Error: Could not find VeeamItUpPlus.ps1" -ForegroundColor Red
    Write-Host "Expected location: $mainApp" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Please ensure you're running this script from the VeeamItUpPlus root directory." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
} 