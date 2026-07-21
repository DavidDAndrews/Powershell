@{
    # Module identity
    ModuleVersion     = '0.1.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Andrews'
    Description       = 'Auditing and reporting tools for Group Policy Objects in Active Directory.'

    # Runtime requirements
    PowerShellVersion = '5.1'
    RequiredModules   = @('GroupPolicy')

    # Module entry point
    RootModule        = 'GPO-Audit.psm1'

    # Exported public functions
    FunctionsToExport = @('Get-GPOInventory')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('GPO', 'GroupPolicy', 'ActiveDirectory', 'Audit')
            ProjectUri = ''
        }
    }
}
