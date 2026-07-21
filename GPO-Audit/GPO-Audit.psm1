#Requires -Version 5.1
#Requires -Modules GroupPolicy

<#
.SYNOPSIS
    GPO-Audit PowerShell Module
.DESCRIPTION
    A module for auditing Group Policy Objects (GPOs) in an Active Directory environment.
    Provides functions to inventory, compare, and report on GPO configurations.
#>

# Dot-source all Private functions
Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
    . $_.FullName
}

# Dot-source all Public functions and export them
$PublicFunctions = Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue
foreach ($function in $PublicFunctions) {
    . $function.FullName
}

Export-ModuleMember -Function $PublicFunctions.BaseName
