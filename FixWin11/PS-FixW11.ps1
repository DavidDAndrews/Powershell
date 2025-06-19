## Script Created by David Andrews (C) 2022 All Rights Reserved
## Last Update Jan 25, 2025 
## This is my Windows Maintenance Script that performs the following functions
## Copies down DISM ISO Image to check Windows System Files Integrity to Local C: Drive
## Performs DISM  Analysis and Repairs any Files Straying from Baseline ISO
## Performs Full Checkdisk with Repair on Drives C: and (A:-Z: if existent)
## Performs Windows Updates
## Performs Disk Cleanup
## Performs Log Cleanup of All System Logs
## Automatic Restart of System
[CmdletBinding(
    SupportsShouldProcess = $true,    # Enables -WhatIf and -Confirm parameters
    DefaultParameterSetName = "Default",
    HelpUri = "https://github.com/DavidDAndrews/PS-FixW11",
    ConfirmImpact = "High"            # High impact operations require confirmation
)]
param(
    [Parameter(
        ParameterSetName = "Default",
        HelpMessage = "Number of days before files are deleted"
    )]
    [int]$DaysToDelete = 1,
    
    [Parameter(
        ParameterSetName = "Default",
        HelpMessage = "Number of days before unused profiles are deleted"
    )]
    [int]$ProfileAge = 30,
    
    [Parameter(
        ParameterSetName = "Default",
        HelpMessage = "Skip Windows Update check/install"
    )]
    [switch]$SkipWindowsUpdate,
    
    [Parameter(
        ParameterSetName = "Default",
        HelpMessage = "Skip system restart"
    )]
    [switch]$NoRestart,
    
    [Parameter(
        ParameterSetName = "Default",
        HelpMessage = "Path to ISO source folder"
    )]
    [string]$ISOSourcePath = "\\192.168.111.10\nas-data\ISO\WINDOWS"
)

#region CONFIGURABLE VARIABLES - MODIFY THESE FOR YOUR ENVIRONMENT
# ============================================================================
# NETWORK PATHS AND ISO CONFIGURATIONS
# ============================================================================

# Base network path for ISO files
$ISO_SOURCE_PATH = "\\192.168.111.10\nas-data\ISO\WINDOWS"

# ISO file names for different Windows versions
$ISO_FILES = @{
    'WIN11'   = "W11PRO-24H2.ISO"    # Windows 11 Pro ISO
    'WIN10'   = "W10PRO-1809.ISO"    # Windows 10 Pro ISO
    'SVR2022' = "W2022.ISO"          # Windows Server 2022 ISO
    'SVR2019' = "W2019-1809.ISO"     # Windows Server 2019 ISO
    'SVR2016' = "W2016-1607.ISO"     # Windows Server 2016 ISO
}

# WIM index values for different installations
$WIM_VALUES = @{
    'DESKTOP'     = "1"    # Standard desktop installations
    'SERVER_CORE' = "1"    # Server Core installations
    'SERVER_FULL' = "2"    # Full Server installations with GUI
}

# ============================================================================
# MAINTENANCE CONFIGURATIONS
# ============================================================================

# Cleanup thresholds
$DEFAULT_DAYS_TO_DELETE = 1     # Days before temp files are deleted
$PROFILE_AGE_LIMIT = 30         # Days before unused profiles are considered stale
$IIS_LOG_AGE_LIMIT = 60        # Days before IIS logs are deleted

# Maintenance paths to clean
$CLEANUP_PATHS = @{
    'WINDOWS_TEMP'    = "$env:windir\Temp"
    'SYSTEM_TEMP'     = "C:\Windows\Temp"
    'USER_TEMP'       = "C:\Users\*\AppData\Local\Temp"
    'IIS_LOGS'        = "C:\inetpub\logs\LogFiles"
    'CBS_LOGS'        = "C:\Windows\logs\CBS"
    'MINIDUMPS'       = "$env:windir\minidump"
    'PREFETCH'        = "$env:windir\Prefetch"
    'ERROR_REPORTS'   = "C:\ProgramData\Microsoft\Windows\WER"
    'CONFIG_MSI'      = "C:\Config.Msi"
    'INTEL'           = "C:\Intel"
}

# ============================================================================
# SCRIPT BEHAVIOR CONFIGURATIONS
# ============================================================================

# Error handling preferences
$ErrorActionPreference = "Stop"              # Stop on errors by default
$VerbosePreference = "Continue"             # Show verbose output

# Logging configuration
$LOG_PATH = "C:\SVC"                        # Path for log files
$LOG_PREFIX = "Clean-"                      # Prefix for log files
$LOG_EXTENSION = ".log"                     # Log file extension

#endregion CONFIGURABLE VARIABLES

<#
.NOTES
    CONFIGURATION INSTRUCTIONS:
    
    1. ISO_SOURCE_PATH: 
       - Set this to your network share or local path containing Windows ISO files
       - Example: "\\server\share\ISO" or "D:\ISO"
    
    2. ISO_FILES:
       - Update the ISO filenames to match your environment
       - Ensure the ISO names exactly match your available files
    
    3. WIM_VALUES:
       - Modify if your WIM indexes differ from standard Microsoft images
       - Use 'dism /get-wiminfo /wimfile:install.wim' to verify correct index
    
    4. CLEANUP_PATHS:
       - Add or remove paths based on your cleanup requirements
       - Use environment variables where possible for compatibility
    
    5. MAINTENANCE CONFIGURATIONS:
       - Adjust retention periods based on your storage and compliance needs
       - All values are in days
    
    6. LOG_PATH:
       - Set to a location with adequate space and permissions
       - Ensure the path exists before running the script
#>

# Function definitions must come before they are used
function Write-BoxedText {
    param (
        [string]$Title,
        [string[]]$Messages,
        [string]$ForegroundColor = 'White'
    )
    
    # Get the longest message length for box width
    $maxLength = ($Messages | Measure-Object -Property Length -Maximum).Maximum
    $maxLength = [Math]::Max($maxLength, $Title.Length)
    
    # Simple box-drawing characters that are more compatible
    $topLeft = [char]0x250C     # ┌
    $topRight = [char]0x2510    # ┐
    $bottomLeft = [char]0x2514  # └
    $bottomRight = [char]0x2518 # ┘
    $horizontal = [char]0x2500  # ─
    $vertical = [char]0x2502    # │
    $leftT = [char]0x251C      # ├
    $rightT = [char]0x2524     # ┤
    
    # Create horizontal line
    $horizontalLine = $horizontal.ToString() * ($maxLength + 2)
    
    # Get console width and calculate padding for centering
    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    $boxWidth = $maxLength + 4  # Total width of box including borders and padding
    $leftPadding = " " * [Math]::Max(0, [Math]::Floor(($consoleWidth - $boxWidth) / 2))
    
    # Output the box
    Write-Host ($leftPadding + $topLeft + $horizontalLine + $topRight) -ForegroundColor $ForegroundColor
    
    if ($Title) {
        Write-Host ($leftPadding + $vertical + " " + $Title.PadRight($maxLength) + " " + $vertical) -ForegroundColor $ForegroundColor
        Write-Host ($leftPadding + $leftT + $horizontalLine + $rightT) -ForegroundColor $ForegroundColor
    }
    
    foreach ($msg in $Messages) {
        Write-Host ($leftPadding + $vertical + " " + $msg.PadRight($maxLength) + " " + $vertical) -ForegroundColor $ForegroundColor
    }
    
    Write-Host ($leftPadding + $bottomLeft + $horizontalLine + $bottomRight) -ForegroundColor $ForegroundColor
}

Clear-Host

$OSVersion = Get-CimInstance Win32_OperatingSystem
$BuildNumber = $OSVersion.BuildNumber
$ISOFile = if ($null -ne $DestinationISO -and $DestinationISO.Length -gt 0) {
    Split-Path $DestinationISO -Leaf
} else {
    "No ISO specified"
}
# Helper functions for different message types
function Write-WarningBox {
    param([string]$Message)
    Write-BoxedText -Title "! WARNING" -Messages @($Message) -ForegroundColor Yellow
}

function Write-ErrorBox {
    param([string]$Message)
    Write-BoxedText -Title "X ERROR" -Messages @($Message) -ForegroundColor Red
}

function Write-SuccessBox {
    param([string]$Message)
    Write-BoxedText -Title "√ SUCCESS" -Messages @($Message) -ForegroundColor Green
}

# Self-elevate the script to run with admin privileges
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Attempting to run script as administrator..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

## Automatically detect Windows version and set $MyWinVer
$OSInfo = Get-WmiObject Win32_OperatingSystem
$OSVersion = [System.Environment]::OSVersion.Version
$OSProductType = $OSInfo.ProductType # 1 = Workstation, 2 = Domain Controller, 3 = Server
$OSCaption = $OSInfo.Caption

# Initialize variables
$MyWinVer = $null
$WimVal = "1" # Default value
$ISO = $null

# Determine OS Version and Type
if ($OSProductType -eq 1) {
    # Workstation (Windows 10/11)
    if ($OSVersion.Major -eq 10) {
        if ($OSVersion.Build -ge 22000) {
            $MyWinVer = "WIN-11"
            $ISO = "W11PRO-24H2.ISO"
            $detectedOS = "Windows 11"
        } else {
            $MyWinVer = "WIN-10"
            $ISO = "W10PRO-1809.ISO"
            $detectedOS = "Windows 10"
        }
    }
} else {
    # Server versions
    if ($OSCaption -match "2016") {
        if ($OSCaption -match "Server Core") {
            $MyWinVer = "2016SC"
            $ISO = "W2016-1607.ISO"
        } else {
            $MyWinVer = "2016DE"
            $WimVal = "2"
            $ISO = "W2016-1607.ISO"
        }
        $detectedOS = "Windows Server 2016"
    }
    elseif ($OSCaption -match "2019") {
        if ($OSCaption -match "Server Core") {
            $MyWinVer = "2019SC"
            $ISO = "W2019-1809.ISO"
        } else {
            $MyWinVer = "2019DE"
            $WimVal = "2"
            $ISO = "W2019-1809.ISO"
        }
        $detectedOS = "Windows Server 2019"
    }
    elseif ($OSCaption -match "2022") {
        if ($OSCaption -match "Server Core") {
            $MyWinVer = "2022SC"
            $ISO = "W2022.ISO"
        } else {
            $MyWinVer = "2022DE"
            $WimVal = "2"
            $ISO = "W2022.ISO"
        }
        $detectedOS = "Windows Server 2022"
    }
}

# Create the information display
if ($MyWinVer) {
    Write-BoxedText -Title "SYSTEM DETECTION" -Messages @(
        "$detectedOS detected",
        "Build Number: $($OSVersion.Build)",
        "System Type: $MyWinVer",
        "Using ISO: $ISO",
        "WIM Value: $(if ($WimVal) { $WimVal } else { 'Not Required' })"
    ) -ForegroundColor Green
} else {
    Write-BoxedText -Title "SYSTEM DETECTION ERROR" -Messages @(
        "Unable to automatically detect Windows version",
        "OS Caption: $($OSInfo.Caption)",
        "Version: $($OSVersion.ToString())",
        "Build: $($OSVersion.Build)"
    ) -ForegroundColor Red
}

# Verify that we successfully detected the OS
if (-not $MyWinVer) {
    Write-Host "Error: Unable to automatically detect Windows version." -ForegroundColor Red
    Write-Host "OS Details:" -ForegroundColor Yellow
    Write-Host "Caption: $($OSInfo.Caption)" -ForegroundColor Yellow
    Write-Host "Version: $($OSVersion.ToString())" -ForegroundColor Yellow
    Write-Host "Build: $($OSVersion.Build)" -ForegroundColor Yellow
    Exit 1
}

# Display detected OS information
#Write-Host "Using ISO: $ISO" -ForegroundColor Green
#Write-Host "WIM Value: $WimVal" -ForegroundColor Green

## NAS Source for ISO Files in case they are missing from C: Drive
## For example path should map out to \\10.11.11.10\DATA\ISO\WINDOWS\ISOIMAGE.ISO 
$NasIP = "192.168.111.10"
$NasShare = "nas-data"
$NasFolderPath = "ISO\WINDOWS"
$SourceISO="\\"+$NasIP+"\"+$NasShare+"\"+$NasFolderPath+"\"+$ISO
## Specify the Drive Letter that the ISO Will be copied down to
$DestDrive="C:\"
## Specify the Name of the Local folder where the ISO will be placed
$DestFolder="SVC"
## Files/Logs/Objects in Cleanup Routine older than this number of days will be deleted 
$DaysToDelete = 1
## Discovered User Profiles that havent logged in for more than this number of days will be deleted
$ProfileAge= 30
## Specify the Backup Folder To Rotate All The Event Logs to a Subfolder i.e. February-18 will
## Be created there and log logs will be saved there before wiping the event logs clean 
$Today = Get-Date -Format "MMMM-dd"
$EventLogBackupFolder = $DestDrive+"Logs\" + "$Today"
##################################################################################################
## Variable Declarations and Constants

## Setup Paths to ISOs
$DestPath=$DestDrive+$DestFolder+'\'
$DestinationISO = $DestPath+$ISO
$Logfile=("C:\SVC\Clean-" + (get-date -format "MM-d-yy") + '.log')

## Begin the timer
$StartTime = (Get-Date)

# Detect Elevation and Exit if not elevated:
$CurrentUser=[System.Security.Principal.WindowsIdentity]::GetCurrent()
$UserPrincipal=New-Object System.Security.Principal.WindowsPrincipal($CurrentUser)
$AdminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator
$IsAdmin=$UserPrincipal.IsInRole($AdminRole)
if ($IsAdmin) {[console]::beep(784,150)}
else {
        throw "Script is not running elevated, which means your are not running as Admin which is required. Restart the script from an elevated prompt."
        [console]::beep(100,2000)
    }
start-sleep -s 3
Clear-Host

## Make Sure We are Using TLS Version 1.2 or Higher
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

## Installs Nuget Package
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force:$true -Confirm:$false | Out-Null

## Tests if the log file already exists and Deletes old file if there is a conflict
if(Test-Path $Logfile)
    {
    #Delete previous file if one exists from same day
    Remove-Item $Logfile -Force -Verbose
    ## Starts a transcript Log of Activities in User Desktop
    Write-Host (Start-Transcript -Path $Logfile) -ForegroundColor Green
    } 
else 
    {
    ## Starts a transcript Log of Activities in User Desktop
    Write-Host (Start-Transcript -Path $Logfile) -ForegroundColor Green
    }


## Function Plays a few Notes to Mission Impossible tune
Function Use-MissionImpossible
{
[console]::beep(784,150)
Start-Sleep -m 300
[console]::beep(784,150)
Start-Sleep -m 300
[console]::beep(932,150)
Start-Sleep -m 150
[console]::beep(1047,150)
Start-Sleep -m 150
[console]::beep(784,150)
Start-Sleep -m 300
[console]::beep(784,150)
}
## End Function Play MI 

## Function Plays Nintendo Mario Tune
Function Use-Mario
{
[console]::beep(659,100) ##E
[console]::beep(659,100) ##E
Start-Sleep -m 250
[console]::beep(659,100) ##E
Start-Sleep -m 250
[console]::beep(523,100) ##C
[console]::beep(659,100) ##E
Start-Sleep -m 250
[console]::beep(784,100) ##G
Start-Sleep -m 475
[console]::Beep(395,250) ##G
}
## Improved by WDA Mar 31 2023
#End Play Nintendo

Function Start-CleanMGR {
    Try{
        Write-Host "Windows Disk Clean is running.                                                                  " -NoNewline -ForegroundColor DarkGreen 
        Start-Process -FilePath Cleanmgr -ArgumentList '/sagerun:100' -Wait 
        Write-Host "[DONE]" -ForegroundColor DarkGreen 
    }
    Catch [System.Exception]{
        Write-host "cleanmgr is not installed! To use this portion of the script you must install the following windows features:" -ForegroundColor Red -NoNewline 
        Write-host "[ERROR]" -ForegroundColor Red 
    }
} 

#####################################################################################
################################  START OF EXECUTION ################################
#####################################################################################

## Display Intro Screen
Write-Host ""
## Test for and Build the Drive Letters string based on on your system for Volume-Repair & Check i.e. ACD will be the string if Drives A, C and D are found
$ExistingDrives=$null
if (Test-Path "A:") {$ExistingDrives=$ExistingDrives+'A'}
if (Test-Path "B:") {$ExistingDrives=$ExistingDrives+'B'}
if (Test-Path "C:") {$ExistingDrives=$ExistingDrives+'C'}
if (Test-Path "D:") {$ExistingDrives=$ExistingDrives+'D'}
if (Test-Path "E:") {$ExistingDrives=$ExistingDrives+'E'}
if (Test-Path "F:") {$ExistingDrives=$ExistingDrives+'F'}
if (Test-Path "G:") {$ExistingDrives=$ExistingDrives+'G'}
if (Test-Path "H:") {$ExistingDrives=$ExistingDrives+'H'}
if (Test-Path "I:") {$ExistingDrives=$ExistingDrives+'I'}
if (Test-Path "J:") {$ExistingDrives=$ExistingDrives+'J'}
if (Test-Path "K:") {$ExistingDrives=$ExistingDrives+'K'}
if (Test-Path "L:") {$ExistingDrives=$ExistingDrives+'L'}
if (Test-Path "M:") {$ExistingDrives=$ExistingDrives+'M'}
if (Test-Path "N:") {$ExistingDrives=$ExistingDrives+'N'}
if (Test-Path "O:") {$ExistingDrives=$ExistingDrives+'O'}
if (Test-Path "P:") {$ExistingDrives=$ExistingDrives+'P'}
if (Test-Path "Q:") {$ExistingDrives=$ExistingDrives+'Q'}
if (Test-Path "R:") {$ExistingDrives=$ExistingDrives+'R'}
if (Test-Path "S:") {$ExistingDrives=$ExistingDrives+'S'}
if (Test-Path "T:") {$ExistingDrives=$ExistingDrives+'T'}
if (Test-Path "U:") {$ExistingDrives=$ExistingDrives+'U'}
if (Test-Path "V:") {$ExistingDrives=$ExistingDrives+'V'}
if (Test-Path "W:") {$ExistingDrives=$ExistingDrives+'W'}
if (Test-Path "X:") {$ExistingDrives=$ExistingDrives+'X'}
if (Test-Path "Y:") {$ExistingDrives=$ExistingDrives+'Y'}
if (Test-Path "Z:") {$ExistingDrives=$ExistingDrives+'Z'}

Write-BoxedText -Title "SYSTEM MAINTENANCE" -Messages @(
    "PRESS CTRL-C TO ABORT NOW",
    "",
    "WINDOWS",
    "Powershell Maintenance",
    "and Cleanup Routines",
    "",
    "(C) 2025 David Andrews"
) -ForegroundColor White

Write-BoxedText -Title "IMPORTANT NOTICE" -Messages @(
    "Please check that the ISO & file/path referenced below",
    "corresponds to your system. This is critical for the",
    "script to run properly. This script must also be run from",
    "the privilege elevated Shortcut which is included in the",
    "SVC folder and named Maintenance. This shortcut can be",
    "moved to your desktop for convenience."
) -ForegroundColor Blue

Write-Host ""

# Center the date display
$dateText = "Today is $($StartTime | Select-Object -ExpandProperty DateTime)"
$consoleWidth = $Host.UI.RawUI.WindowSize.Width
$leftPadding = " " * [Math]::Max(0, [Math]::Floor(($consoleWidth - $dateText.Length) / 2))
Write-Host ($leftPadding + $dateText) -ForegroundColor Green

Write-BoxedText -Title "SYSTEM INFORMATION" -Messages @(
    "Host: $(Hostname)",
    "Drive Letters $ExistingDrives were discovered and will be checked!"
) -ForegroundColor Green

Write-BoxedText -Title "ISO SOURCE" -Messages @(
    "Source Path: $SourceISO"
) -ForegroundColor White
Write-Host ""

## Play intro MI tune
Use-MissionImpossible
Write-Host ""

# Display a custom message with red background and bright yellow text
Write-Host "Press CTRL-C to abort this script now..." -BackgroundColor Red -ForegroundColor Yellow

# Add a slight delay to ensure the message is visible before the progress bar starts
Start-Sleep -Milliseconds 500

# Display a regressive progress bar for 15 seconds
for ($i = 15; $i -ge 0; $i--) {
    Write-Progress -Activity "Time remaining: $i seconds" -Status "Please wait..." -PercentComplete ((15 - $i) / 15 * 100)
    Start-Sleep -Seconds 1
}

# Clear the progress bar
Write-Progress -Activity "Time remaining" -Completed

## Checks if ISO is already on Local Drive
If (Test-Path $DestinationISO)
    {
    ## Yes
    Write-Host ""
    Write-Host "   Windows ISO file was detected at " $DestinationISO -ForegroundColor Green
    [console]::beep(1000,300)
    }
else 
    {
    ## No
    if (-Not (Test-Path $DestPath)) 
        ## Create Local Folder
        {
        #Make folder First if Non-existent and Then Copy Down ISO
        New-Item -Path $DestDrive -Name $DestFolder -ItemType "directory" -Force
        ## Copy down Windows ISO Image from NAS Source 
        [console]::beep(100,1000)
        Write-Host "" 
        Write-BoxedText -Title "ISO DOWNLOAD REQUIRED" -Messages @(
            "COPYING DOWN WINDOWS ISO IMAGE TO LOCAL DRIVE SINCE",
            "IT WAS NOT FOUND IN SERVICE FOLDER LOCALLY"
        ) -ForegroundColor DarkYellow
        Copy-Item -Path $SourceISO -Destination $DestPath -Force
        }
    else  
        {
        ## Just Copy down Windows ISO from NAS Source
        [console]::beep(100,2000)
        Write-Host "" 
        Write-BoxedText -Title "ISO DOWNLOAD REQUIRED" -Messages @(
            "COPYING DOWN WINDOWS ISO IMAGE TO LOCAL DRIVE SINCE",
            "IT WAS NOT FOUND IN SERVICE FOLDER LOCALLY"
        ) -ForegroundColor DarkYellow
        Copy-Item -Path $SourceISO -Destination $DestPath -Force
        }
    }

## System Maintenance with DISM Repair Tool Using Local ISO Image
Write-Host "" 
Write-BoxedText -Title "WINDOWS HEALTH CHECK" -Messages @(
    "THIS WILL TAKE QUITE A",
    "BIT. PLEASE BE PATIENT."
) -ForegroundColor White

Write-BoxedText -Title "DISM HEALTH SCAN" -ForegroundColor White
Dism /online /cleanup-image /scanhealth

Write-BoxedText -Title "HEALTH DETERMINATION" -ForegroundColor White
dism /online /cleanup-image /checkhealth

Write-BoxedText -Title "APPLYING HEALTH FIXES" -ForegroundColor White

Write-BoxedText -Title "MOUNTING WINDOWS IMAGE" -ForegroundColor White
Mount-DiskImage -ImagePath $DestinationISO
$Disk = ((Get-DiskImage $DestinationISO | Get-Volume).DriveLetter)
$Disk = $Disk + ':'

Write-BoxedText -Title "DISK ISO MOUNTED" -Messages @(
    "AS DRIVE LETTER $DISK"
) -ForegroundColor White

Write-BoxedText -Title "PERFORMING REPAIRS" -ForegroundColor White
dism /online /cleanup-image /restorehealth /source:WIM:$Disk\sources\install.wim:$WimVal /limitaccess

Write-BoxedText -Title "DISMOUNTING WINDOWS IMAGE" -ForegroundColor White
Dismount-DiskImage -ImagePath $DestinationISO

Write-BoxedText -Title "RUNNING SYSTEM FILE CHECK" -ForegroundColor White
sfc /scannow

Write-BoxedText -Title "RUN VOLUME REPAIR" -Messages @(
    "REPAIRING VOLUME(S) $ExistingDrives"
) -ForegroundColor White

## Run a Repair-Volumes on Volume Drive Letters Defined in Variable $ExistingDrives
Repair-Volume -DriveLetter $ExistingDrives -OfflineScanAndFix
Write-Host ""

## Gathers the amount of disk space used before running the script
$BeforeUsage = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq "3" } | Select-Object SystemName,
@{ Name = "Drive" ; Expression = { ( $_.DeviceID ) } },
@{ Name = "Size (GB)" ; Expression = {"{0:N1}" -f ( $_.Size / 1gb)}},
@{ Name = "FreeSpace (GB)" ; Expression = {"{0:N1}" -f ( $_.Freespace / 1gb ) } },
@{ Name = "PercentFree" ; Expression = {"{0:P1}" -f ( $_.FreeSpace / $_.Size ) } } |
    Format-Table -AutoSize |
    Out-String

## Lets Start Actually Cleaning
Write-BoxedText -Title "STARTING THE ACTUAL CLEANING PROCESSES" -ForegroundColor DarkGreen

## Archive and Clear Out Event Logs
Write-BoxedText -Title "ARCHIVE EVENT LOGS" -ForegroundColor DarkGreen
$LogNames = (get-WinEvent -ListLog * | Where-Object{$_.RecordCount -gt 0}) | ForEach-Object{$_.LogName}
"Exporting $($LogNames.count) Logs to $($EventLogBackupFolder)..."
If (!(Test-Path $EventLogBackupFolder)) {New-Item $EventLogBackupFolder -Type Directory -Force}
Foreach ($Log in $LogNames) {
    $LogNamesFolder = "$($EventLogBackupFolder)\$($Log.Replace("/","_"))" + ".evtx"
    wevtutil epl $Log $LogNamesFolder /ow:true
    wevtutil cl $Log
}
Write-Host "" 

## Stops the windows update service so that c:\windows\softwaredistribution can be cleaned up
Write-BoxedText -Title "STARTING WINDOWS UPDATE" -Messages @(
    "CLEANUP ROUTINES"
) -ForegroundColor DarkGreen
Write-Host ""
Write-BoxedText -Title "STOPPING WIN UPDATE SVC" -ForegroundColor DarkGreen
Get-Service -Name wuauserv | Stop-Service -Force -ErrorAction SilentlyContinue
Write-Host ""  

## Deletes the contents of windows software distribution.
Write-BoxedText -Title "DELETING OLD UPDATE FILES" -ForegroundColor DarkGreen
Get-ChildItem "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -recurse -ErrorAction SilentlyContinue 
Write-Host "The Contents of Windows SoftwareDistribution have been removed successfully!" -ForegroundColor DarkGreen 
Write-Host "" 

## Deletes the contents of the Windows Temp folder.
Write-BoxedText -Title "DELETING WIN TEMP FOLDER" -ForegroundColor DarkGreen
Get-ChildItem "C:\Windows\Temp\*" -Recurse -Force  -ErrorAction SilentlyContinue |
    Where-Object { ($_.CreationTime -lt $(Get-Date).AddDays( - $DaysToDelete)) } | Remove-Item -force -recurse -ErrorAction SilentlyContinue 
Write-host "The Contents of `$env:TEMP have been removed successfully!" -ForegroundColor DarkGreen
Write-Host "" 

## Deletes all files and folders in user's Temp folder older then $DaysToDelete
Write-BoxedText -Title "DELETING USER TEMP FOLDER" -Messages @(
    "FILES OLDER THAN $DaysToDelete Days"
) -ForegroundColor DarkGreen
Get-ChildItem "C:\users\*\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { ($_.CreationTime -lt $(Get-Date).AddDays( - $DaysToDelete))} |
    Remove-Item -force -recurse -ErrorAction SilentlyContinue 
Write-Host "The contents of `$env:TEMP have been removed successfully!" -ForegroundColor DarkGreen 
Write-Host "" 

## Removes all files and folders in user's Temporary Internet Files older then $DaysToDelete
Write-BoxedText -Title "DELETING TEMP INTERNET" -Messages @(
    "FILES OLDER THAN $DaysToDelete Days"
) -ForegroundColor DarkGreen
Get-ChildItem "C:\users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\*" `
    -Recurse -Force  -ErrorAction SilentlyContinue |
    Where-Object {($_.CreationTime -lt $(Get-Date).AddDays( - $DaysToDelete))} |
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue 
Write-Host "All Temporary Internet Files have been removed successfully!" -ForegroundColor DarkGreen 
Write-Host ""

## Removes *.log from C:\windows\CBS
Write-BoxedText -Title "DELETING CBS LOG FILES" -ForegroundColor DarkGreen
if(Test-Path C:\Windows\logs\CBS\){
    Get-ChildItem "C:\Windows\logs\CBS\*.log" -Recurse -Force -ErrorAction SilentlyContinue |
        remove-item -force -recurse -ErrorAction SilentlyContinue 
    Write-Host "All CBS logs have been removed successfully!" -ForegroundColor DarkGreen 
} else {
    Write-WarningBox "C:\Windows\logs\CBS\ does not exist, there is nothing to Clean!"
}
Write-Host ""

## Cleans IIS Logs older then $DaysToDelete
Write-BoxedText -Title "DELETING IIS SERVER LOG" -Messages @(
    "FILES OLDER THAN $DaysToDelete Days"
) -ForegroundColor DarkGreen
if (Test-Path C:\inetpub\logs\LogFiles\) {
    Get-ChildItem "C:\inetpub\logs\LogFiles\*" -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { ($_.CreationTime -lt $(Get-Date).AddDays(-60)) } | Remove-Item -Force  -Recurse -ErrorAction SilentlyContinue
    Write-Host "All IIS Logfiles over $DaysToDelete days old have been removed Successfully!" -ForegroundColor DarkGreen 
} else {
    Write-WarningBox "C:\inetpub\logs\LogFiles\ does not exist, there is nothing to Clean!"
}
Write-Host ""

## Removes C:\Config.Msi
Write-BoxedText -Title "DELETING C:\Config.Msi" -ForegroundColor DarkGreen
if (test-path C:\Config.Msi){
    remove-item -Path C:\Config.Msi -force -recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "C:\Config.Msi does not exist, there is nothing to Clean!"
}
Write-Host ""

## Removes c:\Intel
Write-BoxedText -Title "DELETING C:\Intel" -ForegroundColor DarkGreen
if (test-path c:\Intel){
    remove-item -Path c:\Intel -force -recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "c:\Intel does not exist, there is nothing to Clean!"
}
Write-Host ""

## Removes c:\Dell
Write-BoxedText -Title "DELETING C:\Dell" -ForegroundColor DarkGreen
if (test-path c:\Dell){
    remove-item -Path c:\Dell -force -recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "c:\Dell does not exist, there is nothing to Clean!"
}
Write-Host ""

## Removes c:\PerfLogs
Write-BoxedText -Title "DELETING PERF LOGS" -ForegroundColor DarkGreen
if (test-path c:\PerfLogs){
    remove-item -Path c:\PerfLogs -force -recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "c:\PerfLogs does not exist, there is nothing to Clean!"
}
Write-Host ""

## Removes $env:windir\memory.dmp
Write-BoxedText -Title "DELETING WINDOWS CRASHDUMPS" -ForegroundColor DarkGreen
if (test-path $env:windir\memory.dmp){
    remove-item $env:windir\memory.dmp -force  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "C:\Windows\memory.dmp does not exist, there is nothing to Clean!"
}
Write-Host ""

## Removes rogue folders
Write-BoxedText -Title "DELETING ROGUE FOLDERS" -ForegroundColor DarkGreen
if (test-path c:\BadFolder){
    remove-item -Path c:\BadFolder -force -recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "C:\Badfolder does not exist, there is nothing to Clean!"
}
Write-Host ""

## Removes Windows Error Reporting files
Write-BoxedText -Title "DELETING WINDOWS ERROR FILES" -ForegroundColor DarkGreen
if (test-path C:\ProgramData\Microsoft\Windows\WER){
    Get-ChildItem -Path C:\ProgramData\Microsoft\Windows\WER -Recurse | Remove-Item -force -recurse  -ErrorAction SilentlyContinue
    Write-host "Deleting Windows Error Reporting files" -ForegroundColor DarkGreen 
} else {
    Write-WarningBox "C:\ProgramData\Microsoft\Windows\WER does not exist, there is nothing to Clean!"
}
Write-Host ""

## Cleans up c:\windows\temp
Write-BoxedText -Title "DELETING WINDOWS TEMP FOLDER" -ForegroundColor DarkGreen
if (Test-Path $env:windir\Temp\) {
    Remove-Item -Path "$env:windir\Temp\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "C:\Windows\Temp does not exist, there is nothing to Clean!"
}
Write-Host ""

## Cleans up minidump files
Write-BoxedText -Title "DELETING WINDOWS MINIDUMPS" -ForegroundColor DarkGreen
if (Test-Path $env:windir\minidump\) {
    Remove-Item -Path "$env:windir\minidump\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "$env:windir\minidump\ does not exist, there is nothing to Clean!"
}
Write-Host ""

## Cleans up prefetch
Write-BoxedText -Title "CLEANING WINDOWS PREFETCH" -ForegroundColor DarkGreen
if (Test-Path $env:windir\Prefetch\) {
    Remove-Item -Path "$env:windir\Prefetch\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "$env:windir\Prefetch\ does not exist, there is nothing to Clean!"
}
Write-Host ""

## Cleans up user temp folders
Write-BoxedText -Title "CLEANING USER TEMP FOLDER" -ForegroundColor DarkGreen
if (Test-Path "C:\Users\*\AppData\Local\Temp\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Temp\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "C:\Users\*\AppData\Local\Temp\ does not exist, there is nothing to Clean!"
}
Write-Host ""

## Cleans up Windows error reporting
Write-BoxedText -Title "CLEANING USER WER FOLDER" -ForegroundColor DarkGreen
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\WER\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\WER\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "C:\ProgramData\Microsoft\Windows\WER does not exist, there is nothing to Clean!"
}
Write-Host ""

## Cleans up users temporary internet files
Write-BoxedText -Title "CLEANING ALL USERS TMP FOLDERS" -ForegroundColor DarkGreen
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\*" -Force -Recurse  -ErrorAction SilentlyContinue 
} else {
    Write-WarningBox "C:\Users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\ does not exist! "
}
Write-Host ""

## Cleans up Internet Explorer cache
Write-BoxedText -Title "CLEANING INTERNET EXPLORER CACHE" -ForegroundColor DarkGreen
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatCache\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatCache\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatCache\ does not exist! "
}

## Cleans up Internet Explorer cache
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatUaCache\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatUaCache\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatUaCache\ does not exist! "
}
Write-Host ""

## Cleans up Internet Explorer download history
Write-BoxedText -Title "CLEANING IE RELATED HISTORY" -ForegroundColor DarkGreen
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\IEDownloadHistory\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\IEDownloadHistory\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "C:\Users\*\AppData\Local\Microsoft\Windows\IEDownloadHistory\ does not exist! "
}

## Cleans up Internet Cache
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\ does not exist! "
}

## Cleans up Internet Cookies
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\INetCookies\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\INetCookies\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "C:\Users\*\AppData\Local\Microsoft\Windows\INetCookies\ does not exist! "
}
Write-Host ""

## Cleans up terminal server cache
Write-BoxedText -Title "CLEANING TERMINAL SERVER CACHE" -ForegroundColor DarkGreen
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Terminal Server Client\Cache\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Terminal Server Client\Cache\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "C:\Users\*\AppData\Local\Microsoft\Terminal Server Client\Cache\ does not exist! "
}
Write-host "Removing System and User Temp Files." -ForegroundColor DarkGreen 
Write-Host ""

## Removes the hidden recycling bin.
Write-BoxedText -Title "REMOVING HIDDEN RECYCLE BIN" -ForegroundColor DarkGreen
if (Test-path 'C:\$Recycle.Bin'){
    Remove-Item 'C:\$Recycle.Bin' -Recurse -Force  -ErrorAction SilentlyContinue
} else {
    Write-WarningBox "C:\`$Recycle.Bin does not exist, there is nothing to Clean! "
}
Write-Host ""

## CLEAN OUT OLD USER PROFILES OLDER THAN $PROFILEAGE DAYS

Write-BoxedText -Title "STARTING USER PROFILE CLEANUP" -ForegroundColor DarkGreen
Write-Host "Checking for user profiles that are older than $ProfileAge days..." -ForegroundColor DarkGreen 
Get-WmiObject -Class Win32_UserProfile | Where-Object {(!$_.Special) -and ($_.ConvertToDateTime($_.LastUseTime) -lt (Get-Date).AddDays(-$ProfileAge)) -and ($_.SID -notmatch '-500$')} |
ForEach-Object {
$_ | Remove-WmiObject
}
Write-Host ""

## CLEAN OUT ALL WINDOWS SNAPSHOTS / SHADOW COPIES
Write-BoxedText -Title "DELETING WINDOWS SHADOW COPIES" -ForegroundColor DarkGreen
Invoke-Expression "vssadmin.exe Delete Shadows /ALL /Quiet"
Write-Host ""   

## Checks the version of PowerShell to empty recycle bin properly
Write-BoxedText -Title "DUMP OUT RECYCLE BIN" -ForegroundColor DarkGreen
## If PowerShell version 4 or below 
if ($PSVersionTable.PSVersion.Major -le 4) {
    ## Empties the recycling bin, the desktop recyling bin
    $Recycler = (New-Object -ComObject Shell.Application).NameSpace(0xa)
    $Recycler.items() | ForEach-Object { 
        ## If PowerShell version 4 or below
        Remove-Item -Include $_.path -Force -Recurse 
        Write-Host "The recycling bin has been cleaned up successfully! " -NoNewline -ForegroundColor DarkGreen 
    }
} elseif ($PSVersionTable.PSVersion.Major -ge 5) {
        ## If PowerShell version 5 is running on the machine the following will process
        Clear-RecycleBin -DriveLetter C:\ -Force 
        Write-Host "The recycling bin has been cleaned up successfully!                                               " -ForegroundColor DarkGreen
}
Write-Host ""

## Restarts wuauserv Windows Updates Service
Get-Service -Name wuauserv | Start-Service -ErrorAction SilentlyContinue

## Clean out all system Logs in Windows
Write-BoxedText -Title "RESET AND CLEAN WINDOWS LOGS" -ForegroundColor DarkGreen
Get-EventLog -LogName * | ForEach-Object { Clear-EventLog $_.Log } -ErrorAction SilentlyContinue

## Gathers disk usage after running the Clean Routines.
$AfterUsage = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq "3" } | Select-Object SystemName,
@{ Name = "Drive" ; Expression = { ( $_.DeviceID ) } },
@{ Name = "Size (GB)" ; Expression = {"{0:N1}" -f ( $_.Size / 1gb)}},
@{ Name = "FreeSpace (GB)" ; Expression = {"{0:N1}" -f ( $_.Freespace / 1gb ) } },
@{ Name = "PercentFree" ; Expression = {"{0:P1}" -f ( $_.FreeSpace / $_.Size ) } } |
    Format-Table -AutoSize | Out-String

## Check for and Perform Windows Updates if needed (Patching) 
Write-BoxedText -Title "RUN WINDOWS UPDATE" -ForegroundColor DarkGreen
Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module PSWindowsUpdate -Confirm:$False -Force:$true | Out-Null
Get-WindowsUpdate
Install-WindowsUpdate -Confirm:$false
Write-Host "" 
Write-BoxedText -Title "WINDOWS UPDATES COMPLETED" -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen


Write-BoxedText -Title "FINAL CLEANING WITH CLEAN MGR" -ForegroundColor DarkGreen
# Setup Cleanmgr Sageset profile:
Write-Host "Starting Disk Cleanup utility..." -ForegroundColor DarkGreen
$ErrorActionPreference = "SilentlyContinue"
$CleanMgrKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
if (-not (get-itemproperty -path "$CleanMgrKey\Temporary Files" -name StateFlags0001))
    {
        set-itemproperty -path "$CleanMgrKey\Active Setup Temp Folders" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\BranchCache" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Downloaded Program Files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Internet Cache Files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Memory Dump Files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Old ChkDsk Files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Previous Installations" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Recycle Bin" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Service Pack Cleanup" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Setup Log Files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\System error memory dump files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\System error minidump files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Temporary Files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Temporary Setup Files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Thumbnail Cache" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Update Cleanup" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Upgrade Discarded Files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\User file versions" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Windows Defender" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Windows Error Reporting Archive Files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Windows Error Reporting Queue Files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Windows Error Reporting System Archive Files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Windows Error Reporting System Queue Files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Windows ESD installation files" -name StateFlags0001 -type DWORD -Value 2
        set-itemproperty -path "$CleanMgrKey\Windows Upgrade Log Files" -name StateFlags0001 -type DWORD -Value 2
    }
# Kick it off
Write-Host "Starting Cleanmgr with full set of checkmarks (might take a while)..." -ForegroundColor DarkGreen
$Process = (Start-Process -FilePath "$env:systemroot\system32\cleanmgr.exe" -ArgumentList "/sagerun:1" -Wait -PassThru)
Write-Host "Clean Manager Finished  with exitcode [$($Process.ExitCode)]."   -ForegroundColor DarkGreen      
Write-Host ""
## END OF CLEAN MGR SECTION

## Record Stop Global timer
$EndTime=(Get-Date)

## Display Summary
Write-BoxedText -Title "JOB SUMMARY" -ForegroundColor White

Write-Host "Machine Name: $(Hostname)" -ForegroundColor Green 
Write-Host ""

## Sends the disk usage before running the Clean script
Write-BoxedText -Title "DISK USAGE BEFORE" -ForegroundColor DarkYellow
Write-host $BeforeUsage -ForegroundColor DarkYellow

## Sends the disk usage after running the Clean script
Write-BoxedText -Title "DISK USAGE AFTER" -ForegroundColor White
Write-Host $AfterUsage -ForegroundColor Green

Write-Host "Execution of Maintenance Script completed at: $(Get-Date | Select-Object -ExpandProperty DateTime)" -ForegroundColor White 
Write-Host "Code Execution Time : $(($EndTime - $StartTime).Minutes) minutes and $(($EndTime - $StartTime).Seconds) seconds" -ForegroundColor Green 

Write-BoxedText -Title "SCRIPT COMPLETION" -Messages @(
    "DAVID'S SCRIPT HAS",
    "EXECUTED SUCCESSFULLY!"
) -ForegroundColor Green

Write-BoxedText -Title "SYSTEM REBOOT" -Messages @(
    "REBOOTING SYSTEM NOW!",
    "BOOT TIME REPAIR WILL OCCUR NOW!",
    "IT WILL TAKE A WHILE TO BOOT AS THE",
    "FILE SYSTEM PERFORMS A CHECK!",
    "DO NOT RESET!!!"
) -ForegroundColor Red

## Completed Tasks Stop Logging!
Write-Host (Stop-Transcript) -ForegroundColor DarkGreen

## Sound Boot Countdown Warning
[console]::beep(1000,500)
Start-Sleep 1
[console]::beep(1000,500)
Start-Sleep 1   
[console]::beep(1000,500)
Start-Sleep 1    
[console]::beep(1000,500)   
Start-Sleep 1
[console]::beep(1000,500)
Start-Sleep 1   
[console]::beep(1000,500)
Start-Sleep 1    
[console]::beep(1000,500)
Start-Sleep 1    
[console]::beep(1000,500)
Start-Sleep 1    
[console]::beep(100,2000)

## RESTART NOW! 
Restart-Computer -Force:$true -Confirm:$false

# Add configuration file support
function Get-ScriptConfig {
    $configPath = Join-Path $PSScriptRoot "maintenance-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath | ConvertFrom-Json
            return $config
        }
        catch {
            Write-LogMessage "Error reading config file: $_" -Level Error
            return $null
        }
    }
    return $null
}

# Load config if available
$config = Get-ScriptConfig
if ($config) {
    $DaysToDelete = $config.DaysToDelete
    $ProfileAge = $config.ProfileAge
    # ... other config values
}

# Add comment-based help
<#
.SYNOPSIS
    Comprehensive Windows system maintenance and cleanup script.
.DESCRIPTION
    Performs system maintenance tasks including:
    - Windows system file integrity checks
    - Disk cleanup and optimization
    - Windows Update installation
    - System logs cleanup
    - Temporary file removal
    - User profile cleanup
.PARAMETER DaysToDelete
    Number of days before temporary files are deleted
.PARAMETER ProfileAge
    Number of days before unused user profiles are deleted
.PARAMETER SkipWindowsUpdate
    Skip Windows Update check and installation
.PARAMETER NoRestart
    Skip system restart after maintenance
.PARAMETER ISOSourcePath
    Path to Windows ISO source files
.EXAMPLE
    .\PS-FixW11.ps1 -DaysToDelete 7 -ProfileAge 60
.NOTES
    Author: David Andrews
    Last Updated: 2024
#>

# Add better error handling function
function Write-LogMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet('Info','Warning','Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        'Info'    { Write-Host $logMessage -ForegroundColor Green }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Error'   { Write-Host $logMessage -ForegroundColor Red }
    }
    
    Add-Content -Path $Logfile -Value $logMessage
}

# Add try/catch blocks around critical operations
try {
    Write-LogMessage "Starting system maintenance"
    
    # Disk space before
    $BeforeUsage = Get-DiskSpace
    Write-LogMessage "Initial disk space: $($BeforeUsage)"
    
    # Main operations in try/catch blocks
    try {
        # DISM operations
        Write-LogMessage "Starting DISM health check"
        Dism /online /cleanup-image /scanhealth
    }
    catch {
        Write-LogMessage "DISM operation failed: $_" -Level Error
    }
    
    # Continue with other operations...
}
catch {
    Write-LogMessage "Critical error occurred: $_" -Level Error
    exit 1
}

# Add progress tracking
$progressSteps = @(
    "System File Check",
    "Disk Cleanup",
    "Windows Update",
    "Profile Cleanup",
    "Log Cleanup"
)

$currentStep = 0
$totalSteps = $progressSteps.Count

foreach ($step in $progressSteps) {
    $currentStep++
    $percentComplete = ($currentStep / $totalSteps) * 100
    
    Write-Progress -Activity "Windows Maintenance" -Status $step -PercentComplete $percentComplete
    
    switch ($step) {
        "System File Check" {
            Write-LogMessage "Starting System File Check"
            # SFC operations...
        }
        "Disk Cleanup" {
            Write-LogMessage "Starting Disk Cleanup"
            # Cleanup operations...
        }
        # Add other steps...
    }
}

function Backup-SystemState {
    param(
        [string]$BackupPath = "C:\Maintenance\Backups"
    )
    
    try {
        $date = Get-Date -Format "yyyy-MM-dd-HHmm"
        $backupFolder = Join-Path $BackupPath $date
        
        # Create backup folder
        New-Item -Path $backupFolder -ItemType Directory -Force | Out-Null
        
        # Backup event logs
        Write-LogMessage "Backing up event logs"
        $LogNames | ForEach-Object {
            $logPath = Join-Path $backupFolder "$_.evtx"
            wevtutil epl $_ $logPath
        }
        
        # Backup registry keys that will be modified
        Write-LogMessage "Backing up registry settings"
        reg export "HKLM\Software\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches" `
            (Join-Path $backupFolder "VolumeCaches.reg") /y
        
        Write-LogMessage "System state backup completed successfully"
        return $true
    }
    catch {
        Write-LogMessage "Backup failed: $_" -Level Error
        return $false
    }
}

# Create system restore point before making changes
function New-MaintenanceRestorePoint {
    try {
        Write-LogMessage "Creating system restore point"
        Checkpoint-Computer -Description "Before Windows Maintenance Script" -RestorePointType "MODIFY_SETTINGS"
        return $true
    }
    catch {
        Write-LogMessage "Failed to create restore point: $_" -Level Error
        return $false
    }
}

# Example usage:
Write-BoxedText -Title "WINDOWS HEALTH CHECK" -Messages @(
    "THIS WILL TAKE QUITE A",
    "BIT. PLEASE BE PATIENT."
) -ForegroundColor White

Write-Host ""

Write-BoxedText -Title "DISM HEALTH SCAN" -ForegroundColor White
Dism /online /cleanup-image /scanhealth

Write-Host ""

Write-BoxedText -Title "HEALTH DETERMINATION" -ForegroundColor White
dism /online /cleanup-image /checkhealth

Write-Host ""

Write-BoxedText -Title "APPLYING HEALTH FIXES" -ForegroundColor White

Write-Host ""

Write-BoxedText -Title "MOUNTING WINDOWS IMAGE" -ForegroundColor White
Mount-DiskImage -ImagePath $DestinationISO
$Disk = ((Get-DiskImage $DestinationISO | Get-Volume).DriveLetter)
$Disk = $Disk + ':'

Write-BoxedText -Title "DISK ISO MOUNTED" -Messages @(
    "AS DRIVE LETTER $DISK"
) -ForegroundColor White

Write-Host ""

Write-BoxedText -Title "PERFORMING REPAIRS" -ForegroundColor White
dism /online /cleanup-image /restorehealth /source:WIM:$Disk\sources\install.wim:$WimVal /limitaccess

Write-Host ""

Write-BoxedText -Title "DISMOUNTING WINDOWS IMAGE" -ForegroundColor White
Dismount-DiskImage -ImagePath $DestinationISO

# System File Check section
Write-BoxedText -Title "RUNNING SYSTEM FILE CHECK" -ForegroundColor White
sfc /scannow

Write-Host ""

Write-BoxedText -Title "RUN VOLUME REPAIR" -Messages @(
    "REPAIRING VOLUME(S) $ExistingDrives"
) -ForegroundColor White

# Cleaning Process Section
Write-BoxedText -Title "STARTING THE ACTUAL CLEANING PROCESSES" -ForegroundColor DarkGreen

Write-Host ""

Write-BoxedText -Title "ARCHIVE EVENT LOGS" -ForegroundColor DarkGreen

# Windows Update Section
Write-BoxedText -Title "STARTING WINDOWS UPDATE" -Messages @(
    "CLEANUP ROUTINES"
) -ForegroundColor DarkGreen

Write-Host ""

Write-BoxedText -Title "STOPPING WIN UPDATE SVC" -ForegroundColor DarkGreen

# For warning messages, you can use a different style
function Write-WarningBox {
    param(
        [string]$Message
    )
    Write-BoxedText -Title "! WARNING" -Messages @($Message) -ForegroundColor Yellow
}

# For error messages
function Write-ErrorBox {
    param(
        [string]$Message
    )
    Write-BoxedText -Title "X ERROR" -Messages @($Message) -ForegroundColor Red
}

# For success messages
function Write-SuccessBox {
    param(
        [string]$Message
    )
    Write-BoxedText -Title "√ SUCCESS" -Messages @($Message) -ForegroundColor Green
}

# Example usage for status messages:
Write-SuccessBox "The Contents of Windows SoftwareDistribution have been removed successfully!"

# For the final completion message
Write-BoxedText -Title "SCRIPT COMPLETION" -Messages @(
    "DAVID'S SCRIPT HAS",
    "EXECUTED SUCCESSFULLY!"
) -ForegroundColor Green

Write-BoxedText -Title "SYSTEM REBOOT" -Messages @(
    "REBOOTING SYSTEM NOW!",
    "BOOT TIME REPAIR WILL OCCUR NOW!",
    "IT WILL TAKE A WHILE TO BOOT AS THE",
    "FILE SYSTEM PERFORMS A CHECK!",
    "DO NOT RESET!!!"
) -ForegroundColor Red

Write-BoxedText -Title "SYSTEM DETECTION" -Messages @(
    "Windows 11 detected with Build Number: $($OSVersion.Build)",
    "Using ISO: $ISO",
    "WIM Value: $WimVal",
    "Script is running elevated."
) -ForegroundColor White
Write-Host ""

# Get system information safely
try {
    $OSVersion = Get-CimInstance Win32_OperatingSystem
    $BuildNumber = $OSVersion.BuildNumber

    # Create messages array with basic information
    $messages = @(
        "Windows Build: $BuildNumber"
    )

    # Add ISO information if available
    if ($SourceISO) {
        $messages += "ISO Source: $SourceISO"
    } else {
        $messages += "ISO Source: Not yet defined"
    }

    # Create and display the system information box
    Write-BoxedText -Title "SYSTEM INFORMATION" -Messages $messages -ForegroundColor White
}
catch {
    Write-Host "Error getting system information: $($_.Exception.Message)" -ForegroundColor Red
}

# Safely get WIM value
$WimValDisplay = if ($WimVal) {
    $WimVal
} else {
    "not defined"
}

# Create the system detection box
Write-BoxedText -Title "SYSTEM DETECTION" -Messages @(
    "Windows 11 detected with Build Number: $BuildNumber",
    "Using ISO: $ISO",
    "WIM Value: $WimValDisplay",
    "Script is running elevated."
) -ForegroundColor White

# Pause briefly to show the box
Start-Sleep -Seconds 2

# Continue with the rest of your script...