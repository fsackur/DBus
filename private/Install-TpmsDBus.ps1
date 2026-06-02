function Install-TpmsDBus {
    [CmdletBinding()]
    param ()

    $PackageName = "Tmds.DBus.Protocol"
    $Version = [version]"0.94.1"
    $MaxVersion = [version]::new($Version.Major, $Version.Minor, [int]::MaxValue)
    $Package = Find-Package $PackageName -MinimumVersion $Version -MaximumVersion $MaxVersion -Verbose -Debug
    $Result = $Package | Install-Package -Scope CurrentUser -Force -Verbose -Debug #-ForceBootstrap
    $Result
}

# 1. install mono-complete
# 2. get exe from https://dist.nuget.org/win-x86-commandline/latest/nuget.exe
# 3. mono nuget.exe install $PackageName -Version $Version -OutputDirectory ./upstream/ -Verbosity detailed -ConfigFile ~/.nuget/NuGet/NuGet.Config
# 4. Common denominator is netstandard2.0:
#     $Libs | %{[o]@{Name = $_.Name; Targets = @(gci "$_/lib" -Name) -match "^net" | Sort-Object}} | fl Name, Targets
#
# 5. gci ./upstream/ | % {gci "$_/lib/netstandard2.0"} | copy -Destination ./lib/
