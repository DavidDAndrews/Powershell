## Script Created by David Andrews (C) 2022 All Rights Reserved
## Last Update Mar 19, 2022 10:01PM
## This is my Windows Maintenance Script that performs the following functions
## Copies down DISM ISO Image to check Windows System Files Integrity to Local C: Drive
## Performs DISM  Analysis and Repairs any Files Straying from Baseline ISO
## Performs Full Checkdisk with Repair on Drives C: and (A:-Z: if existent)
## Performs Windows Updates
## Performs Disk Cleanup
## Performs Log Cleanup of All System Logs
## Automatic Restart of System
##################################################################################################
## IMPORTANT!  
## S E T U P   A C C O R D I N G   T O   Y O U R   E N V I R O N M E N T   B E L O W
##################################################################################################
## Uncomment your OS version Server Core or Desktop Experience
## $MyWinVer = "2012R2"
## $MyWinVer = "2016SC"
## $MyWinVer = "2016DE"
## $MyWinVer = "2019SC"
## $MyWinVer = "2019DE"
## $MyWinVer = "2022SC"
## $MyWinVer = "2022DE"
## $MyWinVer = "WIN-10"
$MyWinVer = "WIN-11"

## Set WIM DISM Instance Parameter and ISO Image To Use Based On Your OS Version
If ($MyWinVer -eq "WIN-10") {
    $WimVal="1"
    $ISO="W10PRO-1809.ISO"
}
If ($MyWinVer -eq "WIN-11") {
    $WimVal="1"
    $ISO="W11PRO-21H2.ISO"
}
If ($MyWinVer -eq "2016SC") {
    $WimVal="1"
    $ISO="W2016-1607.ISO"
}
If ($MyWinVer -eq "2016DE") {
    $WimVal="2"
    $ISO="W2016-1607.ISO"
}
If ($MyWinVer -eq "2019SC") {
    $WimVal="1"
    $ISO="W2019-1809.ISO"
}
If ($MyWinVer -eq "2019DE") {
    $WimVal="2"
    $ISO="W2019-1809.ISO"
}
If ($MyWinVer -eq "2022SC") {
    $WimVal="1"
    $ISO="W2022.ISO"
}
If ($MyWinVer -eq "2022DE") {
    $WimVal="2"
    $ISO="W2022.ISO"
}

## NAS Source for ISO Files in case they are missing from C: Drive
## For example path should map out to \\10.11.11.10\DATA\ISO\WINDOWS\ISOIMAGE.ISO 
$NasIP = "10.11.11.10"
$NasShare = "DATA"
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
if ($IsAdmin) {Write-Host "Script is running elevated." -ForegroundColor Green}
else {
        throw "Script is not running elevated, which means your are not running as Admin which is required. Restart the script from an elevated prompt."
        [console]::beep(100,2000)
    }

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
[console]::beep(659,250) ##E
[console]::beep(659,250) ##E
[console]::beep(659,300) ##E
[console]::beep(523,250) ##C
[console]::beep(659,250) ##E
[console]::beep(784,300) ##G
}
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
Write-Host "                                                             " -ForegroundColor White 
Write-Host "*************************************************************" -ForegroundColor White 
Write-Host "***                       WINDOWS                         ***" -ForegroundColor White 
Write-Host "***                Powershell Maintenance                 ***" -ForegroundColor White 
Write-Host "***                 and Cleanup Routines                  ***" -ForegroundColor White 
Write-Host "*************************************************************" -ForegroundColor White 
Write-Host "***                (C) 2022 David Andrews                 ***" -ForegroundColor White 
Write-Host "*************************************************************" -ForegroundColor White 
Write-Host "                                                            " -ForegroundColor Blue
Write-host "  Please check that the ISO & file/path referenced below    " -ForegroundColor Blue 
Write-host "  corresponds  to your system.  This is critical for the    " -ForegroundColor Blue
Write-host "  script to run properly. This script must also be run from " -ForegroundColor Blue  
Write-host "  the privilege elevated Shorcut which is included  in  the " -ForegroundColor Blue 
Write-host "  SVC folder and named Maintenance. This shorcut can be     " -ForegroundColor Blue
Write-Host "  moved to your desktop for convenience.                     " -ForegroundColor Blue
Write-Host "                                                            " -ForegroundColor Blue 
Write-Host "*************************************************************" -ForegroundColor Red 
Write-host "***               PRESS CTRL-C TO ABORT NOW               ***" -ForegroundColor Red 
Write-Host "*************************************************************" -ForegroundColor Red 
Write-Host ""
Write-Host "       Today is "($StartTime | Select-Object -ExpandProperty DateTime) -ForegroundColoR Green
Write-Host "*************************************************************" -ForegroundColoR Green
Write-Host "Host:"(Hostname) -ForegroundColor Green
Write-Host "Drive Letters " -NoNewLine -ForegroundColor Green ; Write-host $ExistingDrives -NoNewLine -ForegroundColor Red; Write-host " were discovered and will be checked!" -ForegroundColor Green
Write-Host "*************************************************************" -ForegroundColoR Green
Write-Host "ISO image Source" $SourceISO -ForegroundColor White
Write-Host ""

## Play intro MI tune
Use-MissionImpossible
Write-Host ""
Write-Host "Launching in 15 seconds..." -Foregroundcolor DarkYellow
Start-Sleep 15

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
        Write-Host "*************************************************************" -ForegroundColor DarkYellow 
        Write-host "*** COPYING DOWN WINDOWS ISO IMAGE TO LOCAL DRIVE SINCE   ***" -ForegroundColor DarkYellow
        Write-host "***     IT WAS NOT FOUND IN SERVICE FOLDER LOCALLY        ***" -ForegroundColor DarkYellow
        Write-Host "*************************************************************" -ForegroundColor DarkYellow
        Copy-Item -Path $SourceISO -Destination $DestPath -Force
        }
    else  
        {
        ## Just Copy down Windows ISO from NAS Source
        [console]::beep(100,2000)
        Write-Host "" 
        Write-Host "*************************************************************" -ForegroundColor DarkYellow 
        Write-host "*** COPYING DOWN WINDOWS ISO IMAGE TO LOCAL DRIVE SINCE   ***" -ForegroundColor DarkYellow
        Write-host "***     IT WAS NOT FOUND IN SERVICE FOLDER LOCALLY        ***" -ForegroundColor DarkYellow
        Write-Host "*************************************************************" -ForegroundColor DarkYellow
        Copy-Item -Path $SourceISO -Destination $DestPath -Force
        }
    }

## System Maintenance with DISM Repair Tool Using Local ISO Image
Write-Host "" 
Write-Host "*******************************" -ForegroundColor White 
Write-Host "***  WINDOWS HEALTH CHECK   ***"
Write-Host "*** THIS WILL TAKE QUITE A  ***" -ForegroundColor White 
Write-Host "*** BIT. PLEASE BE PATIENT. ***" -ForegroundColor White 
Write-Host "*******************************" -ForegroundColor White
Write-Host ""
Write-Host "*******************************" -ForegroundColor White 
Write-Host "***    DISM HEALTH SCAN     ***" -ForegroundColor White 
Write-Host "*******************************" -ForegroundColor White 
Dism /online /cleanup-image /scanhealth
Write-Host "" 
Write-Host "*******************************" -ForegroundColor White 
Write-Host "***   HEALTH DETERMINATION  ***" -ForegroundColor White 
Write-Host "*******************************" -ForegroundColor White 
dism /online /cleanup-image /checkhealth
Write-Host "" 
Write-Host "*******************************" -ForegroundColor White 
Write-Host "***  APPLYING HEALTH FIXES  ***" -ForegroundColor White 
Write-Host "*******************************" -ForegroundColor White 
Write-Host "" 
Write-Host "*******************************" -ForegroundColor White 
Write-Host "***  MOUNTING WINDOWS IMAGE ***" -ForegroundColor White 
Write-Host "*******************************" -ForegroundColor White 
Mount-DiskImage -ImagePath $DestinationISO
$Disk = ((Get-DiskImage $DestinationISO | Get-Volume).DriveLetter)
$Disk = $Disk + ':'
Write-Host "*******************************" -ForegroundColor White 
Write-Host "***    DISK ISO MOUNTED     ***" -ForegroundColor White 
Write-Host "***    AS DRIVE LETTER"$DISK"   ***" -ForegroundColor White 
Write-Host "*******************************" -ForegroundColor White 
Write-Host ""
Write-Host "*******************************" -ForegroundColor White 
Write-Host "***    PERFORMING REPAIRS   ***" -ForegroundColor White 
Write-Host "*******************************" -ForegroundColor White
dism /online /cleanup-image /restorehealth /source:WIM:$Disk\sources\install.wim:$WimVal /limitaccess
Write-Host "" 
Write-Host "*******************************" -ForegroundColor White 
Write-Host "***DISMOUNTING WINDOWS IMAGE***" -ForegroundColor White 
Write-Host "*******************************" -ForegroundColor White 
Dismount-DiskImage -ImagePath $DestinationISO

## Do a System File Check to improve Windows OS Integrity
Write-Host "*******************************" -ForegroundColor White 
Write-Host "***RUNNING SYSTEM FILE CHECK***" -ForegroundColor White 
Write-Host "*******************************" -ForegroundColor White 
sfc /scannow
Write-Host "" 
Write-Host "*******************************" -ForegroundColor White 
Write-Host "***    RUN VOLUME REPAIR    ***" -ForegroundColor White 
Write-Host "*******************************" -ForegroundColor White 
Write-Host "  REPAIRING VOLUME(S)  $ExistingDrives" -ForegroundColor White 
Write-Host "*******************************" -ForegroundColor White

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
Write-Host "" 
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "***   STARTING THE ACTUAL   ***" -ForegroundColor DarkGreen 
Write-Host "***   CLEANING  PROCESSES   ***" -ForegroundColor DarkGreen 
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "" 

## Archive and Clear Out Event Logs
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "***   ARCHIVE EVENT LOGS   ***" -ForegroundColor DarkGreen 
Write-Host "*******************************" -ForegroundColor DarkGreen 
$LogNames = (get-WinEvent -ListLog * | Where-Object{$_.RecordCount -gt 0}) | ForEach-Object{$_.LogName}
"Exporting $($LogNames.count) Logs to $($EventLogBackupFolder)..."
If (!(Test-Path $EventLogBackupFolder)) {New-Item $EventLogBackupFolder -Type Directory -Force}
Foreach ($Log in $LogNames) {
    $LogNamesFolder = "$($EventLogBackupFolder)\$($Log.Replace("/","_"))" + ".evtx"
    wevtutil epl $Log $LogNamesFolder /ow:true
    wevtutil cl $Log
}
Write-Host "" 
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "*** STARTING WINDOWS UPDATE ***" -ForegroundColor DarkGreen 
Write-Host "***     CLEANUP ROUTINES    ***" -ForegroundColor DarkGreen 
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "" 
## Stops the windows update service so that c:\windows\softwaredistribution can be cleaned up
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "*** STOPPING WIN UPDATE SVC ***" -ForegroundColor DarkGreen 
Write-Host "*******************************" -ForegroundColor DarkGreen 
Get-Service -Name wuauserv | Stop-Service -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
Write-Host ""  

## Deletes the contents of windows software distribution.
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "***DELETING OLD UPDATE FILES***" -ForegroundColor DarkGreen 
Write-Host "*******************************" -ForegroundColor DarkGreen 
Get-ChildItem "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -recurse -ErrorAction SilentlyContinue 
Write-Host "The Contents of Windows SoftwareDistribution have been removed successfully!" -ForegroundColor DarkGreen 
Write-Host "" 

## Deletes the contents of the Windows Temp folder.
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "***DELETING WIN TEMP FOLDER***" -ForegroundColor DarkGreen 
Write-Host "*******************************" -ForegroundColor DarkGreen 
Get-ChildItem "C:\Windows\Temp\*" -Recurse -Force  -ErrorAction SilentlyContinue |
    Where-Object { ($_.CreationTime -lt $(Get-Date).AddDays( - $DaysToDelete)) } | Remove-Item -force -recurse -ErrorAction SilentlyContinue 
Write-host "The Contents of Windows Temp have been removed successfully!" -ForegroundColor DarkGreen
Write-Host "" 

## Deletes all files and folders in user's Temp folder older then $DaysToDelete
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "   DELETING USER TEMP FOLDER" -ForegroundColor DarkGreen
Write-Host "   FILES OLDER THAN"$DaysToDelete" Days" -ForegroundColor DarkGreen  
Write-Host "*******************************" -ForegroundColor DarkGreen
Get-ChildItem "C:\users\*\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { ($_.CreationTime -lt $(Get-Date).AddDays( - $DaysToDelete))} |
    Remove-Item -force -recurse -ErrorAction SilentlyContinue 
Write-Host "The contents of `$env:TEMP have been removed successfully!" -ForegroundColor DarkGreen 
Write-Host "" 

## Removes all files and folders in user's Temporary Internet Files older then $DaysToDelete
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "   DELETING TEMP INTERNET" -ForegroundColor DarkGreen
Write-Host "   FILES OLDER THAN"$DaysToDelete" Days" -ForegroundColor DarkGreen  
Write-Host "*******************************" -ForegroundColor DarkGreen
Get-ChildItem "C:\users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\*" `
    -Recurse -Force  -ErrorAction SilentlyContinue |
    Where-Object {($_.CreationTime -lt $(Get-Date).AddDays( - $DaysToDelete))} |
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue 
Write-Host "All Temporary Internet Files have been removed successfully!" -ForegroundColor DarkGreen 
Write-Host ""

## Removes *.log from C:\windows\CBS
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "   DELETING CBS LOG FILES" -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if(Test-Path C:\Windows\logs\CBS\){
Get-ChildItem "C:\Windows\logs\CBS\*.log" -Recurse -Force -ErrorAction SilentlyContinue |
    remove-item -force -recurse -ErrorAction SilentlyContinue 
Write-Host "All CBS logs have been removed successfully!" -ForegroundColor DarkGreen 
} else {
    Write-Host "C:\Windows\logs\CBS\ does not exist, there is nothing to Clean! " -NoNewLine -ForegroundColor DarkYellow 
    Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Cleans IIS Logs older then $DaysToDelete
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "   DELETING IIS SERVER LOG" -ForegroundColor DarkGreen
Write-Host "   FILES OLDER THAN"$DaysToDelete" Days" -ForegroundColor DarkGreen  
Write-Host "*******************************" -ForegroundColor DarkGreen
if (Test-Path C:\inetpub\logs\LogFiles\) {
    Get-ChildItem "C:\inetpub\logs\LogFiles\*" -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { ($_.CreationTime -lt $(Get-Date).AddDays(-60)) } | Remove-Item -Force  -Recurse -ErrorAction SilentlyContinue
    Write-Host "All IIS Logfiles over $DaysToDelete days old have been removed Successfully!" -ForegroundColor DarkGreen 
}
else {
    Write-Host "C:\inetpub\logs\LogFiles\ does not exist, there is nothing to Clean! " -NoNewLine -ForegroundColor DarkYellow 
    Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Removes C:\Config.Msi
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "   DELETING C:\Config.Msi      " -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if (test-path C:\Config.Msi){
    remove-item -Path C:\Config.Msi -force -recurse  -ErrorAction SilentlyContinue
} else {
    Write-Host "C:\Config.Msi does not exist, there is nothing to Clean! " -NoNewline -ForegroundColor DarkYellow 
    Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Removes c:\Intel
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "      DELETING C:\Intel        " -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if (test-path c:\Intel){
    remove-item -Path c:\Intel -force -recurse  -ErrorAction SilentlyContinue
} else {
    Write-Host "c:\Intel does not exist, there is nothing to Clean! " -NoNewline -ForegroundColor DarkYellow 
    Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Removes c:\Dell
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "      DELETING C:\Dell         " -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if (test-path c:\Dell){
    remove-item -Path D:\Dell -force -recurse  -ErrorAction SilentlyContinue
} else {
    Write-Host "c:\Dell does not exist, there is nothing to Clean! " -NoNewline -ForegroundColor DarkYellow 
    Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Removes c:\PerfLogs
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "      DELETING PERF LOGS       " -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if (test-path c:\PerfLogs){
    remove-item -Path c:\PerfLogs -force -recurse  -ErrorAction SilentlyContinue
} else {
    Write-Host "c:\PerfLogs does not exist, there is nothing to Clean! " -NoNewline -ForegroundColor DarkYellow 
    Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Removes $env:windir\memory.dmp
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "  DELETING WINDOWS CRASHDUMPS  " -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if (test-path $env:windir\memory.dmp){
    remove-item $env:windir\memory.dmp -force  -ErrorAction SilentlyContinue
} else {
    Write-Host "C:\Windows\memory.dmp does not exist, there is nothing to Clean! " -NoNewline -ForegroundColor DarkYellow 
    Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Removes rogue folders *** Customize if necessary ***
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "  DELETING ROGUE FOLDERS" -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if (test-path c:\BadFolder){
    remove-item -Path c:\BadFolder -force -recurse  -ErrorAction SilentlyContinue
} else {
    Write-Host "C:\Badfolder does not exist, there is nothing to Clean! " -NoNewline -ForegroundColor DarkYellow 
    Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Removes Windows Error Reporting files
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "  DELETING WINDOWS ERROR FILES " -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if (test-path C:\ProgramData\Microsoft\Windows\WER){
    Get-ChildItem -Path C:\ProgramData\Microsoft\Windows\WER -Recurse | Remove-Item -force -recurse  -ErrorAction SilentlyContinue
        Write-host "Deleting Windows Error Reporting files"-ForegroundColor DarkGreen 
    } else {
        Write-Host "C:\ProgramData\Microsoft\Windows\WER does not exist, there is nothing to Clean! " -NoNewline -ForegroundColor DarkYellow 
        Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Removes System and User Temp Files - lots of access denied will occur.
## Cleans up c:\windows\temp
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "  DELETING WINDOWS TEMP FOLDER " -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if (Test-Path $env:windir\Temp\) {
    Remove-Item -Path "$env:windir\Temp\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
        Write-Host "C:\Windows\Temp does not exist, there is nothing to Clean! " -NoNewline -ForegroundColor DarkYellow 
        Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Cleans up minidump files from Windows Blue Screens
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "   DELETING WINDOWS MINIDUMPS  " -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if (Test-Path $env:windir\minidump\) {
    Remove-Item -Path "$env:windir\minidump\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
        Write-Host "$env:windir\minidump\ does not exist, there is nothing to Clean! " -NoNewline -ForegroundColor DarkYellow 
        Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Cleans up prefetch
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "   CLEANING WINDOWS PREFETCH   " -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if (Test-Path $env:windir\Prefetch\) {
    Remove-Item -Path "$env:windir\Prefetch\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
        Write-Host "$env:windir\Prefetch\ does not exist, there is nothing to Clean! " -NoNewline -ForegroundColor DarkYellow 
        Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Cleans up each users temp folder
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "   CLEANING USER TEMP FOLDER   " -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if (Test-Path "C:\Users\*\AppData\Local\Temp\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Temp\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
        Write-Host "C:\Users\*\AppData\Local\Temp\ does not exist, there is nothing to Clean! " -NoNewline -ForegroundColor DarkYellow 
        Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Cleans up all users windows error reporting
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "    CLEANING USER WER FOLDER   " -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\WER\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\WER\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
        Write-Host "C:\ProgramData\Microsoft\Windows\WER does not exist, there is nothing to Clean! " -NoNewline -ForegroundColor DarkYellow 
        Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Cleans up users temporary internet files
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host " CLEANING ALL USERS TMP FOLDERS" -ForegroundColor DarkGreen
Write-Host "*******************************" -ForegroundColor DarkGreen
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\*" -Force -Recurse  -ErrorAction SilentlyContinue 
} else {
        Write-Host "C:\Users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\ does not exist! " -NoNewline -ForegroundColor DarkYellow 
        Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Cleans up Internet Explorer cache
Write-Host "********************************" -ForegroundColor DarkGreen 
Write-Host "CLEANING INTERNET EXPLORER CACHE" -ForegroundColor DarkGreen
Write-Host "********************************" -ForegroundColor DarkGreen
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatCache\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatCache\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
        Write-Host "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatCache\ does not exist! " -NoNewline -ForegroundColor DarkYellow 
        Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}

## Cleans up Internet Explorer cache
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatUaCache\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatUaCache\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
        Write-Host "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatUaCache\ does not exist! " -NoNewline -ForegroundColor DarkYellow 
        Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Cleans up Internet Explorer download history
Write-Host "********************************" -ForegroundColor DarkGreen 
Write-Host "  CLEANING IE RELATED HISTORY" -ForegroundColor DarkGreen
Write-Host "********************************" -ForegroundColor DarkGreen
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\IEDownloadHistory\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\IEDownloadHistory\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
        Write-Host "C:\Users\*\AppData\Local\Microsoft\Windows\IEDownloadHistory\ does not exist! " -NoNewline -ForegroundColor DarkYellow 
        Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}

## Cleans up Internet Cache
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
        Write-Host "C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\ does not exist! " -NoNewline -ForegroundColor DarkYellow 
        Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}

## Cleans up Internet Cookies
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Windows\INetCookies\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Windows\INetCookies\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
        Write-Host "C:\Users\*\AppData\Local\Microsoft\Windows\INetCookies\ does not exist! " -NoNewline -ForegroundColor DarkYellow 
        Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## Cleans up terminal server cache
Write-Host "********************************" -ForegroundColor DarkGreen 
Write-Host " CLEANING TERMINAL SERVER CACHE " -ForegroundColor DarkGreen
Write-Host "********************************" -ForegroundColor DarkGreen
if (Test-Path "C:\Users\*\AppData\Local\Microsoft\Terminal Server Client\Cache\") {
    Remove-Item -Path "C:\Users\*\AppData\Local\Microsoft\Terminal Server Client\Cache\*" -Force -Recurse  -ErrorAction SilentlyContinue
} else {
        Write-Host "C:\Users\*\AppData\Local\Microsoft\Terminal Server Client\Cache\ does not exist! " -NoNewline -ForegroundColor DarkYellow 
        Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-host "Removing System and User Temp Files." -ForegroundColor DarkGreen 
Write-Host ""

## Removes the hidden recycling bin.
Write-Host "********************************" -ForegroundColor DarkGreen 
Write-Host "  REMOVING HIDDEN RECYCLE BIN   " -ForegroundColor DarkGreen
Write-Host "********************************" -ForegroundColor DarkGreen
if (Test-path 'C:\$Recycle.Bin'){
    Remove-Item 'C:\$Recycle.Bin' -Recurse -Force  -ErrorAction SilentlyContinue
} else {
    Write-Host "C:\`$Recycle.Bin does not exist, there is nothing to Clean! " -NoNewline -ForegroundColor DarkYellow 
    Write-Host "[WARNING]" -ForegroundColor DarkYellow 
}
Write-Host ""

## CLEAN OUT OLD USER PROFILES OLDER THAN $PROFILEAGE DAYS

Write-Host "********************************" -ForegroundColor DarkGreen 
Write-Host "  STARTING USER PROFILE CLEANUP " -ForegroundColor DarkGreen
Write-Host "********************************" -ForegroundColor DarkGreen
Write-Host "Checking for user profiles that are older than $ProfileAge days..." -ForegroundColor DarkGreen 
Get-WmiObject -Class Win32_UserProfile | Where-Object {(!$_.Special) -and ($_.ConvertToDateTime($_.LastUseTime) -lt (Get-Date).AddDays(-$ProfileAge)) -and ($_.SID -notmatch '-500$')} |
ForEach-Object {
$_ | Remove-WmiObject
}
Write-Host ""

## CLEAN OUT ALL WINDOWS SNAPSHOTS / SHADOW COPIES
Write-Host "********************************" -ForegroundColor DarkGreen 
Write-Host " DELETING WINDOWS SHADOW COPIES" -ForegroundColor DarkGreen
Write-Host "********************************" -ForegroundColor DarkGreen
Invoke-Expression "vssadmin.exe Delete Shadows /ALL /Quiet"
Write-Host ""   

## Checks the version of PowerShell to empty recycle bin properly
Write-Host "********************************" -ForegroundColor DarkGreen 
Write-Host "      DUMP OUT RECYCLE BIN      " -ForegroundColor DarkGreen
Write-Host "********************************" -ForegroundColor DarkGreen
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
Write-Host "********************************" -ForegroundColor DarkGreen 
Write-Host "  RESET AND CLEAN WINDOWS LOGS  " -ForegroundColor DarkGreen
Write-Host "********************************" -ForegroundColor DarkGreen
Get-EventLog -LogName * | ForEach-Object { Clear-EventLog $_.Log } -ErrorAction SilentlyContinue

## Gathers disk usage after running the Clean Routines.
$AfterUsage = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq "3" } | Select-Object SystemName,
@{ Name = "Drive" ; Expression = { ( $_.DeviceID ) } },
@{ Name = "Size (GB)" ; Expression = {"{0:N1}" -f ( $_.Size / 1gb)}},
@{ Name = "FreeSpace (GB)" ; Expression = {"{0:N1}" -f ( $_.Freespace / 1gb ) } },
@{ Name = "PercentFree" ; Expression = {"{0:P1}" -f ( $_.FreeSpace / $_.Size ) } } |
    Format-Table -AutoSize | Out-String

## Check for and Perform Windows Updates if needed (Patching) 
Write-Host "" 
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "***    RUN WINDOWS UPDATE   ***" -ForegroundColor DarkGreen 
Write-Host "*******************************" -ForegroundColor DarkGreen 
Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module PSWindowsUpdate -Confirm:$False -Force:$true | Out-Null
Get-WindowsUpdate
Install-WindowsUpdate -Confirm:$false
Write-Host "" 
Write-Host "*******************************" -ForegroundColor DarkGreen 
Write-Host "***WINDOWS UPDATES COMPLETED***" -ForegroundColor DarkGreen 
Write-Host "*******************************" -ForegroundColor DarkGreen


Write-Host "********************************" -ForegroundColor DarkGreen 
Write-Host "  FINAL CLEANING WITH CLEAN MGR  " -ForegroundColor DarkGreen
Write-Host "********************************" -ForegroundColor DarkGreen
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
Write-Host "" 
Write-Host "*******************************" -ForegroundColor White 
Write-Host "***      JOB SUMMARY        ***" -ForegroundColor White 
Write-Host "*******************************" -ForegroundColor White 
Write-Host ""
Write-Host "Machine Name:" (Hostname) -ForegroundColor Green 
Write-Host ""
## Sends the disk usage before running the Clean script
Write-Host "*******************************" -ForegroundColor DarkYellow 
Write-Host "***    DISK USAGE BEFORE    ***" -ForegroundColor DarkYellow
Write-Host "*******************************" -ForegroundColor DarkYellow 
Write-host $BeforeUsage  -ForegroundColor DarkYellow
## Sends the disk usage after running the Clean script
Write-Host "" 
Write-Host "*******************************" -ForegroundColor White 
Write-Host "***    DISK USAGE AFTER     ***" -ForegroundColor White
Write-Host "*******************************" -ForegroundColor White
Write-Host $AfterUsage -ForegroundColor Green
Write-Host "" 
Write-Host "Execution of Maintenance Script completed at: "(Get-Date | Select-Object -ExpandProperty DateTime) -ForegroundColor White 
## Calculate amount of seconds your code takes to complete.
Write-Host ""
Write-Host "Code Execution Time : $(($EndTime - $StartTime).Minutes) minutes and $(($EndTime - $StartTime).Seconds) seconds" -ForegroundColor Green 

## Play Nintendo Tune and wait 5 Seconds
Use-Mario
Start-Sleep 5

## All Processes Completed Prepare to Reboot Display Goodbye Message
Write-Host "" 
Write-Host "                           DAVID'S SCRIPT HAS" -ForegroundColor Green 
Write-Host "                         EXECUTED SUCCESSFULLY!" -ForegroundColor Green
Write-Host ""
Write-Host "                    *******************************" -ForegroundColor Red 
Write-Host "                    *** REBOOTING SYSTEM NOW!   ***" -ForegroundColor Red 
Write-Host "                    *******************************" -ForegroundColor Red 
Write-Host "                    *** BOOT TIME REPAIR WILL   ***" -ForegroundColor Red 
Write-Host "                    *** OCCUR NOW! IT WILL TAKE ***" -ForegroundColor Red 
Write-Host "                    *** A WHILE TO BOOT AS THE  ***" -ForegroundColor Red 
Write-Host "                    *** FILE SYSTEM PERFORMS A  ***" -ForegroundColor Red 
Write-Host "                    *** CHECK! DO NOT RESET!!!  ***" -ForegroundColor Red 
Write-Host "                    *******************************" -ForegroundColor Red 
Write-Host "                    *******************************" -ForegroundColor Red 
Write-Host "                    *** REBOOTING SYSTEM NOW!   ***" -ForegroundColor Red 
Write-Host "                    *******************************" -ForegroundColor Red 

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
[console]::beep(1000,500)
Start-Sleep 1    
[console]::beep(100,2000)

## RESTART NOW! 
Restart-Computer -Force:$true -Confirm:$false