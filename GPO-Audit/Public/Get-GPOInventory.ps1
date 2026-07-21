function Get-GPOInventory {
    <#
    .SYNOPSIS
        Retrieves a full inventory of all GPOs in the target domain.

    .DESCRIPTION
        Queries Active Directory for every Group Policy Object and returns a
        rich data object per GPO including metadata, enabled status, WMI filter
        assignment, and (optionally) link details parsed from the GPO XML report.

        Link retrieval requires one Get-GPOReport call per GPO and can be slow
        in large environments. Use -IncludeLinks only when you need link data.

    .PARAMETER Domain
        FQDN of the target domain. Defaults to the current user's domain.

    .PARAMETER IncludeLinks
        When specified, fetches the XML report for each GPO and resolves
        all links (OU, domain, site), their enabled state, and enforcement.

    .OUTPUTS
        PSCustomObject per GPO with the following properties:
            Name, Id, Domain, Owner, Created, Modified,
            GpoStatus, UserSettingsEnabled, ComputerSettingsEnabled,
            WmiFilter, Description, LinkCount, Links (when -IncludeLinks)

    .EXAMPLE
        Get-GPOInventory

    .EXAMPLE
        Get-GPOInventory -Domain "corp.contoso.com" -IncludeLinks |
            Where-Object LinkCount -eq 0 |
            Select-Object Name, Created, Owner

    .EXAMPLE
        Get-GPOInventory -IncludeLinks | Export-Csv -Path ".\GPOInventory.csv" -NoTypeInformation
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter()]
        [string]$Domain = $env:USERDNSDOMAIN,

        [Parameter()]
        [switch]$IncludeLinks
    )

    begin {
        Write-Verbose "Retrieving all GPOs from domain: $Domain"

        try {
            $allGPOs = Get-GPO -All -Domain $Domain -ErrorAction Stop
        }
        catch {
            throw "Failed to retrieve GPOs from '$Domain'. Ensure the GroupPolicy module is available and you have read access. Error: $_"
        }

        Write-Verbose "Found $($allGPOs.Count) GPO(s)."
    }

    process {
        $index  = 0
        $total  = $allGPOs.Count

        foreach ($gpo in $allGPOs) {
            $index++
            Write-Progress -Activity 'GPO Inventory' `
                           -Status "Processing '$($gpo.DisplayName)' ($index of $total)" `
                           -PercentComplete (($index / $total) * 100)

            # ── Determine per-setting enabled states ──────────────────────────
            $userEnabled     = $gpo.GpoStatus -notin @('UserSettingsDisabled',     'AllSettingsDisabled')
            $computerEnabled = $gpo.GpoStatus -notin @('ComputerSettingsDisabled', 'AllSettingsDisabled')

            # ── WMI filter name (null when none assigned) ─────────────────────
            $wmiFilterName = if ($gpo.WmiFilter) { $gpo.WmiFilter.Name } else { $null }

            $entry = [PSCustomObject]@{
                Name                    = $gpo.DisplayName
                Id                      = $gpo.Id.ToString()
                Domain                  = $gpo.DomainName
                Owner                   = $gpo.Owner
                Created                 = $gpo.CreationTime
                Modified                = $gpo.ModificationTime
                GpoStatus               = $gpo.GpoStatus.ToString()
                UserSettingsEnabled     = $userEnabled
                ComputerSettingsEnabled = $computerEnabled
                WmiFilter               = $wmiFilterName
                Description             = $gpo.Description
                LinkCount               = 0
                Links                   = $null
            }

            # ── Optional: resolve links via XML report ────────────────────────
            if ($IncludeLinks) {
                try {
                    Write-Verbose "  Fetching XML report for '$($gpo.DisplayName)'"
                    [xml]$report   = Get-GPOReport -Guid $gpo.Id -ReportType Xml -Domain $Domain -ErrorAction Stop
                    $resolvedLinks = Resolve-GPOLinks -GPOReport $report
                    $entry.Links     = $resolvedLinks
                    $entry.LinkCount = @($resolvedLinks).Count
                }
                catch {
                    Write-Warning "Could not retrieve report for GPO '$($gpo.DisplayName)': $_"
                    $entry.Links     = @()
                    $entry.LinkCount = -1   # -1 signals retrieval failure
                }
            }

            $entry
        }
    }

    end {
        Write-Progress -Activity 'GPO Inventory' -Completed
        Write-Verbose "GPO inventory complete."
    }
}
