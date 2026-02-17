@echo off
REM Enable-PowerShellExecution.bat
REM Helper script to enable PowerShell script execution on new machines
REM Created by David Andrews (C) 2025

echo ============================================================================
echo PowerShell Execution Policy Helper
echo ============================================================================
echo.

REM Check for C:\SVC folder existence
if not exist "C:\SVC\" (
    echo ERROR: C:\SVC folder does not exist!
    echo This folder is required for the FixWindows.ps1 script to function properly.
    echo Please create the C:\SVC folder before running the script.
    echo.
    pause
    exit /b 1
)

REM Check current execution policy
echo Checking current PowerShell execution policy...
for /f "tokens=*" %%i in ('powershell -Command "Get-ExecutionPolicy"') do set CURRENT_POLICY=%%i
echo Current policy: %CURRENT_POLICY%
echo.

REM If already set to a permissive policy, exit
if "%CURRENT_POLICY%"=="RemoteSigned" (
    echo PowerShell execution policy is already set to RemoteSigned.
    echo Scripts can be executed without issues.
    pause
    exit /b 0
)

if "%CURRENT_POLICY%"=="Unrestricted" (
    echo PowerShell execution policy is already set to Unrestricted.
    echo Scripts can be executed without issues.
    pause
    exit /b 0
)

if "%CURRENT_POLICY%"=="Bypass" (
    echo PowerShell execution policy is already set to Bypass.
    echo Scripts can be executed without issues.
    pause
    exit /b 0
)

REM Policy needs to be changed
echo PowerShell execution policy needs to be changed to allow script execution.
echo.
echo Available options:
echo 1. Set RemoteSigned for Current User (Recommended - No admin required)
echo 2. Set RemoteSigned for All Users (Requires administrator privileges)
echo 3. Set Unrestricted for Current User (Less secure)
echo 4. Exit without changes
echo.

set /p choice="Enter your choice (1-4): "

if "%choice%"=="1" goto :set_user_remotesigned
if "%choice%"=="2" goto :set_machine_remotesigned
if "%choice%"=="3" goto :set_user_unrestricted
if "%choice%"=="4" goto :exit_script

echo Invalid choice. Please run the script again.
pause
exit /b 1

:set_user_remotesigned
echo.
echo Setting execution policy to RemoteSigned for current user...
powershell -Command "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force"
if %errorlevel% equ 0 (
    echo SUCCESS: Execution policy set to RemoteSigned for current user.
    echo You can now run PowerShell scripts signed by trusted publishers.
) else (
    echo ERROR: Failed to set execution policy.
    echo You may need to run this as administrator.
)
goto :verify_policy

:set_machine_remotesigned
echo.
echo Setting execution policy to RemoteSigned for all users...
echo This requires administrator privileges.
powershell -Command "Start-Process powershell -ArgumentList '-Command Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force' -Verb RunAs"
if %errorlevel% equ 0 (
    echo Execution policy change initiated. Please check the elevated PowerShell window.
) else (
    echo ERROR: Failed to launch elevated PowerShell.
)
goto :verify_policy

:set_user_unrestricted
echo.
echo WARNING: Setting execution policy to Unrestricted allows all scripts to run.
echo This is less secure than RemoteSigned.
set /p confirm="Are you sure? (Y/N): "
if /i not "%confirm%"=="Y" goto :exit_script

echo Setting execution policy to Unrestricted for current user...
powershell -Command "Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser -Force"
if %errorlevel% equ 0 (
    echo SUCCESS: Execution policy set to Unrestricted for current user.
    echo WARNING: All PowerShell scripts can now run without restrictions.
) else (
    echo ERROR: Failed to set execution policy.
)
goto :verify_policy

:verify_policy
echo.
echo Verifying new execution policy...
for /f "tokens=*" %%i in ('powershell -Command "Get-ExecutionPolicy"') do set NEW_POLICY=%%i
echo New policy: %NEW_POLICY%
echo.

if "%NEW_POLICY%"=="RemoteSigned" (
    echo SUCCESS: PowerShell scripts can now be executed.
    echo You can now run FixWindows.ps1 directly.
) else if "%NEW_POLICY%"=="Unrestricted" (
    echo SUCCESS: PowerShell scripts can now be executed.
    echo You can now run FixWindows.ps1 directly.
) else if "%NEW_POLICY%"=="Bypass" (
    echo SUCCESS: PowerShell scripts can now be executed.
    echo You can now run FixWindows.ps1 directly.
) else (
    echo The execution policy may not have been changed successfully.
    echo Current policy is still: %NEW_POLICY%
    echo.
    echo You can still run FixWindows.ps1 using:
    echo powershell -ExecutionPolicy Bypass -File FixWindows.ps1
)

:exit_script
echo.
echo ============================================================================
echo For more information about PowerShell execution policies, visit:
echo https://docs.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies
echo ============================================================================
pause
exit /b 0