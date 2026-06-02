using namespace Tmds.DBus.Protocol

function Connect-DBus {
    [CmdletBinding()]
    [OutputType([DBusConnection])]
    param (
        [switch]$System
    )

    # see https://tmds.github.io/Tmds.DBus/api/Tmds.DBus.Protocol/Tmds.DBus.Protocol.DBusConnectionOptions.html#Tmds_DBus_Protocol_DBusConnectionOptions_AutoConnect
    if ($System) {
        [DBusConnection]::System
    } else {
        [DBusConnection]::Session
    }
}
