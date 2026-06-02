using namespace Tmds.DBus.Protocol

function Get-DbusService {
    [CmdletBinding()]
    [OutputType([string[]])]
    param (
        [SupportsWildcards()]
        [string[]]$Name
    )

    [DBusConnection]$Conn = Connect-DBus
    $Task = $Conn.ListServicesAsync()
    [string[]]$Services = $Task.Result
    if ($PSBoundParameters.ContainsKey("Name")) {
        $Output = $Services -ilike $Name
        if ($Output) {$Output} else {
            Write-Error "No services found matching '$Name'"
        }
    } else {
        $Services
    }
}
