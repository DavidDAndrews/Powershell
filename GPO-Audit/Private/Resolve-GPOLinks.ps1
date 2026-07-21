function Resolve-GPOLinks {
    <#
    .SYNOPSIS
        Parses a GPO XML report and returns structured link information.
    .DESCRIPTION
        Internal helper. Takes the XML report of a single GPO and returns
        an array of PSCustomObjects describing each location the GPO is linked to.
    .PARAMETER GPOReport
        [xml] object from Get-GPOReport -ReportType Xml.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(Mandatory)]
        [xml]$GPOReport
    )

    $links = $GPOReport.GPO.LinksTo

    if (-not $links) {
        return @()
    }

    # LinksTo may be a single node or an array — normalise to array
    @($links) | ForEach-Object {
        [PSCustomObject]@{
            SOMPath    = $_.SOMPath
            SOMType    = $_.SOMType        # e.g. Domain, OU, Site
            LinkEnabled = [System.Convert]::ToBoolean($_.Enabled)
            Enforced   = [System.Convert]::ToBoolean($_.NoOverride)
        }
    }
}
