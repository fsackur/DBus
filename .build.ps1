using namespace System.Collections.Generic
using namespace System.Management.Automation
using namespace System.Management.Automation.Language
using namespace Microsoft.PowerShell.Commands

<#
    .DESCRIPTION
    Assumes the following layout:

    ├── LICENSE
    ├── <this file>
    ├── Module.psd1
    ├── Classes
    │   └── *.ps1
    ├── Private
    │   └── *.ps1
    ├── Public
    │   └── *.ps1
    └── Tests
        └── *.Tests.ps1

    If the RootModule exists, and contains '#region build-inlines' and '#endregion build-inlines',
    then functions within .ps1 files will be injected into the region. Otherwise, functions will be
    prepended to the RootModule content.

    .NOTES
    This file will update with the SelfUpdate task. To change parameter defaults, create a
    .build.parameters.psd1 file.
#>

[CmdletBinding()]
param
(
    [switch]$Bootstrap,

    [version]$NewVersion,

    [ValidateSet("major", "minor", "patch")]
    [string]$Release,

    [string]$PSGalleryApiKey = $env:PSGalleryApiKey,

    [string]$ModuleName = $(
        $FromFile = $MyInvocation.MyCommand.Name -replace '\.build\.ps1$'
        if ($FromFile) {$FromFile} else {
            $MyInvocation.MyCommand.Source | Split-Path | Split-Path -Leaf
        }
    ),

    [string]$ManifestPath = "$ModuleName.psd1",

    [string[]]$Include = ('*.ps1xml', '*.psrc', 'README*', 'LICENSE*'),

    [string[]]$PSScriptFolder = ('Classes', 'Private', 'Public'),

    [string[]]$DotnetProject,

    [string[]]$TestPath,

    [hashtable]$PesterConfiguration = @{},

    [string]$OutputFolder = 'Build',

    [switch]$CI = ($env:CI -and $env:CI -ne "0"),

    [Microsoft.PowerShell.Commands.ModuleSpecification[]]$BuildDependencies = (
        @{ModuleName = 'InvokeBuild'; ModuleVersion = '5.12.1'},
        @{ModuleName = 'Pester'; ModuleVersion = '5.6.1'},
        @{ModuleName = 'PSScriptAnalyzer'; ModuleVersion = '1.23.0'},
        @{ModuleName = 'Microsoft.PowerShell.PSResourceGet'; ModuleVersion = '1.0.6'}
    )
)

#region Setup
function Get-RelativePath {
    param ([Parameter(Position=0, ValueFromPipeline)][string]$Path)
    process {[System.IO.Path]::GetRelativePath($PWD, $Path)}
}

$BuildScript = $MyInvocation.MyCommand.Source | Get-RelativePath
$ParameterFile = $BuildScript -replace '\.ps1$', '.parameters.psd1'
$WasCalledFromInvokeBuild = (Get-PSCallStack).Command -match 'Invoke-Build'

if ($WasCalledFromInvokeBuild -and (Test-Path $ParameterFile))
{
    $DefaultParameterValues = Invoke-Expression "DATA {$(Get-Content -Raw $ParameterFile)}"

    $BoundParameters = Get-PSCallStack |
        Where-Object Command -eq "Invoke-Build.ps1" |
        Select-Object -Last 1 -ExpandProperty InvocationInfo |
        Select-Object -ExpandProperty BoundParameters

    [string[]]$CommonParameters = ("Verbose", "Debug", "ErrorAction", "WarningAction", "InformationAction", "ErrorVariable", "WarningVariable", "InformationVariable", "ProgressAction", "OutVariable", "OutBuffer", "PipelineVariable", "WhatIf", "Confirm")

    $Parameters = $MyInvocation.MyCommand.Parameters.Values.Name | ? {$_ -notin $CommonParameters}
    $Parameters | ForEach-Object {
        $Value = $null
        if ($BoundParameters.TryGetValue($_, ([ref]$Value))) {
        } elseif ($DefaultParameterValues.ContainsKey($_)) {
            $Value = $DefaultParameterValues[$_]
        } else {
            return
        }
        Set-Variable -Scope Script -Name $_ -Value $Value
    }
}

$Include = $Include
    | Get-ChildItem -ErrorAction Ignore
    | Get-RelativePath

$PSScriptFolder = Get-ChildItem -Directory
    | Where-Object Name -in $PSScriptFolder  # case-insensitive matching
    | Get-RelativePath

$ManifestFile = "$ModuleName.psd1"
#endregion Setup

#region Handle direct invocation (i.e. not Invoke-Build)
if (-not ($Bootstrap -or $WasCalledFromInvokeBuild))
{
    throw "Incorrect usage: '$($MyInvocation.Line)'. Use -Bootstrap to install the InvokeBuild module, then use Invoke-Build to run tasks."
}

function Install-BuildDependencies
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param
    (
        [Parameter(ValueFromPipeline)]
        [ModuleSpecification]$ModuleSpec,

        [switch]$Force
    )

    if ($MyInvocation.ExpectingInput) {[ModuleSpecification[]]$ModuleSpec = $input}

    if (-not $ModuleSpec) {return}
    if (-not ($Force -or $PSCmdlet.ShouldProcess($ModuleSpec, "Install"))) {throw "Confirmation declined."}

    # run in separate process, to avoid "assembly with same name is already loaded"
    # NB. properties differ because ModuleSpec.ToString() prints the original hashtable
    Write-Build -Color Cyan "Installing $ModuleSpec..."
    pwsh -NoProfile -NoLogo -NonInteractive -c "
        `$ProgressPreference = 'Ignore'
        $($ModuleSpec -join ', ') | ForEach-Object {
            Install-Module `$_.ModuleName -MinimumVersion `$_.ModuleVersion -Force -ea Stop *>&1
        }
    "
    if (-not $?) {exit 1}
    Write-Build -Color Cyan " ...done."
}

$InstallBuildDependencies = {
    $IsInteractive = [Environment]::UserInteractive -or -not [Environment]::GetCommandLineArgs().Where({$_.ToLower().StartsWith('-noni')})
    $ShouldConfirm = $IsInteractive -and -not $CI

    $BuildDependencies |
        Where-Object {-not (Import-Module -FullyQualifiedName $_ -PassThru -ErrorAction Ignore)} |
        Install-BuildDependencies -Confirm:$ShouldConfirm
}

$SelfUpdate = {
    $SourceRepo = "fsackur/template"
    $SourceUri = "https://raw.githubusercontent.com/$SourceRepo/refs/heads/main/$BuildScript"
    try
    {
        Invoke-WebRequest $SourceUri -OutFile $BuildScript -ErrorAction Stop
    }
    catch
    {
        $_.ErrorDetails = "Failed to update build script: $_"
        Write-Error -ErrorRecord $_ -ErrorAction Stop
    }

    if (git diff --shortstat --ignore-all-space --ignore-blank-lines $BuildScript)
    {
        Write-Build Red "WARNING: Build script differs from the version in $SourceRepo."
        Write-Build Cyan "Use command: Invoke-Build SelfUpdate, Push"

        if ($WasCalledFromInvokeBuild)
        {
            $Output = git commit -m "update build script" $BuildScript *>&1
            assert $? ($Output | Out-String)
        }
    }
    else
    {
        git restore $BuildScript
    }
}

if ($Bootstrap)
{
    if (-not $WasCalledFromInvokeBuild)
    {
        function Write-Build
        {
            param ([ConsoleColor]$Color, [string]$Text)
            Write-Host -ForegroundColor $Color $Text
        }

        function assert
        {
            param ([bool]$Invariant, [string]$Message)
            if (-not $Invariant) {Write-Build Red $Message; exit 1}
        }
    }

    try {. $SelfUpdate} catch {Write-Build Red $_}

    . $InstallBuildDependencies
    return
}
#endregion Handle direct invocation (i.e. not Invoke-Build)

#region Manifest helpers
class Manifest {
    static [Manifest] ParseFile([string]$Path) {
        return [Manifest][Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    }
    static [Manifest] ParseInput([string]$Content) {
        return [Manifest][Parser]::ParseInput($Content, [ref]$null, [ref]$null)
    }
    [ScriptBlockAst]$Ast
    [string]$Content
    [ICollection[Tuple[ExpressionAst, StatementAst]]]$KeyValuePairs

    Manifest ([ScriptBlockAst]$Ast) {
        $this.Ast = $Ast
        $this.Content = $Ast.Extent.Text
        $this.KeyValuePairs = $Ast.EndBlock.Statements[0].PipelineElements[0].Expression.KeyValuePairs
    }
}

function Read-Manifest {
    [OutputType([Manifest])]
    param ($Path = $ManifestFile)
    [Manifest]::ParseFile($Path)
}

function Get-ManifestValue {
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [Manifest]$Manifest,
        [Parameter(Mandatory, Position = 0)]
        [string]$Key,
        [switch]$AsAst
    )

    process {
        $Tuple = $Manifest.KeyValuePairs | ? {$_.Item1.Value -ieq $Key}
        assert ($Tuple.Count -eq 1) "Non-unique key: '$Key'"
        $Ast = $Tuple.Item2
        if ($AsAst) {
            $Ast
        } else {
            $Ast.SafeGetValue()
        }
    }
}

function Update-ManifestValue {
    [OutputType([Manifest])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [Manifest]$Manifest,
        [Parameter(Mandatory, Position = 0)]
        [string]$Key,
        [Parameter(Mandatory, Position = 1)]
        [string]$Value
    )

    process {
        $OldExtent = $Manifest | Get-ManifestValue $Key -AsAst | % Extent
        $Content = (
            $Manifest.Content.Substring(0, $OldExtent.StartOffset),
            $Value,
            $Manifest.Content.Substring($OldExtent.EndOffset)
        ) -join ""
        [Manifest]::ParseInput($Content)
    }
}

function Write-Manifest {
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [Manifest]$Manifest,
        [string]$Path = $ManifestFile
    )
    process {$Manifest.Content > $Path}
}
#endregion Manifest helpers

$AssertTool = {assert (Get-Command $Tool.ToLower() -ErrorAction Ignore) "$Tool not found"}
task AssertGit {$Tool = "git"; & $AssertTool}
task AssertZip {$Tool = "zip"; & $AssertTool}
task AssertGH {$Tool = "gh"; & $AssertTool; assert ((gh auth status -a -h github.com) -match 'Logged in to github.com account') "GH client needs to log in"}

task InstallBuildDependencies $InstallBuildDependencies

task SelfUpdate $SelfUpdate

task Clean {
    remove $OutputFolder
}

task ReadManifest {
    $Script:Manifest = Read-Manifest
    $Script:RootModule = $Manifest | Get-ManifestValue "RootModule"
    [version]$Script:ManifestVersion = $Manifest | Get-ManifestValue "ModuleVersion"
    [version]$Script:Version = $ManifestVersion
    $Script:Tag = "v$ManifestVersion"

    assert $RootModule "RootModule not set in manifest"
    assert $ManifestVersion "ModuleVersion not set in manifest"

    Write-Build Green "Manifest version: $ManifestVersion"
}

task UpdateVersion ReadManifest, {
    $n, $v = $NewVersion, $ManifestVersion

    $Script:Version = if ($NewVersion)
    {
        $IncOk = (
            ($n.Major -eq ($v.Major + 1) -and $n.Minor -eq 0 -and $n.Build -eq 0) -or
            ($n.Major -eq $v.Major -and $n.Minor -eq ($v.Minor + 1) -and $n.Build -eq 0) -or
            ($n.Major -eq $v.Major -and $n.Minor -eq $v.Minor -and $n.Build -eq ($v.Build + 1))
        )
        assert $IncOk "New version is not a valid major/minor/patch increment. Existing: $ManifestVersion. New: $NewVersion"

        $NewVersion
    }
    elseif ($Release -eq "major")
    {
        [version]::new(($v.Major + 1), 0, 0)
    }
    elseif ($Release -eq "minor")
    {
        [version]::new($v.Major, ($v.Minor + 1), 0)
    }
    elseif ($Release -eq "patch")
    {
        [version]::new($v.Major, $v.Minor, ($v.Build + 1))
    }
    else
    {
        $v
    }

    $Script:Tag = "v$Version"

    if ($Version -gt $ManifestVersion)
    {
        $Script:Manifest = $Script:Manifest | Update-ManifestValue 'ModuleVersion' "'$Version'"
        $Script:Manifest | Write-Manifest
        Write-Build DarkYellow "New manifest version: $Version"
    }
    else
    {
        Write-Build Green "Manifest version unchanged."
    }
}

task BuildDir ReadManifest, UpdateVersion, {
    $Script:BuildDir = [IO.Path]::Combine($PSScriptRoot, $OutputFolder, $ModuleName, $Version)
    $Script:BuiltManifest = Join-Path $BuildDir $ManifestFile
    $Script:BuiltRootModule = Join-Path $BuildDir $RootModule
    New-Item $BuildDir -ItemType Directory -Force | Out-Null
}

task Includes @{
    Inputs = $Include
    Outputs = {$Include | ForEach-Object {Join-Path $BuildDir $_}}
    Jobs = "BuildDir", {
        $Include
            | Split-Path
            | Where-Object Length | Select-Object -Unique
            | ForEach-Object {Join-Path $BuildDir $_}
            | ForEach-Object {New-Item $_ -ItemType Directory -Force | Out-Null}
        $Include
            | ForEach-Object {Copy-Item -Recurse -Force $_ (Join-Path $BuildDir $_)}
    }
}

task BuildPowershell @{
    Inputs = {
        (
            $ManifestFile,
            $RootModule,
            ($PSScriptFolder | Get-ChildItem -Recurse -File -Filter *.ps1)
        ) | Write-Output
    }
    Outputs = {
        $BuiltManifest,
        $BuiltRootModule
    }
    Jobs = "UpdateVersion", "BuildDir", "Includes", {
        $Requirements = @()
        $Usings = @()
        $PublicFunctions = [List[string]]::new()

        $Psm1Content = if (Test-Path $RootModule) {Get-Content -Raw $RootModule} else {""}
        $Psm1Header = $Psm1Content -replace '(?s)(^|\n)#region build-inlines.*'
        $Psm1Footer = $Psm1Content -replace '(?s).*#endregion build-inlines(\n|$)'

        $Content = $PSScriptFolder | ForEach-Object {
            $Label = $_
            $IsPublic = $_ -ilike "Public*"

            $Files = $_ | Get-ChildItem -File -Recurse -Filter *.ps1
            $FileContents = $Files | ForEach-Object {
                $FileAst = [Parser]::ParseFile($_, [ref]$null, [ref]$null)

                if ($IsPublic) {
                    [string[]]$FunctionNames = $FileAst.FindAll({$args[0] -is [FunctionDefinitionAst]}, $false).Name
                    $PublicFunctions.AddRange($FunctionNames)
                }

                $Requirements += $FileAst.ScriptRequirements.Extent.Text
                $Usings += $FileAst.UsingStatements.Extent.Text

                # find furthest offset from start
                [int]$SnipOffset = (
                    $FileAst.ScriptRequirements.Extent.EndOffset,
                    $FileAst.UsingStatements.Extent.EndOffset,
                    $FileAst.ParamBlock.Extent.EndOffset  # will only exist to hold PSSA suppressions
                ) |
                    Sort-Object |
                    Select-Object -Last 1

                $_Content = $FileAst.Extent.Text
                $_Content.Substring($SnipOffset).Trim()
            }

            "#region $Label", ($FileContents -join "`n`n"), "#endregion $Label" | Write-Output
        }

        $Requirements = $Requirements | Write-Output | ForEach-Object Trim | Sort-Object -Unique
        $Usings = $Usings | Write-Output | ForEach-Object Trim | Sort-Object -Unique

        $Psm1Content = (
            $Requirements,
            $Usings,
            $Psm1Header,
            "",
            ($Content -join "`n`n"),
            "",
            $Psm1Footer
        ) | Write-Output
        $Psm1Content.Trim() > (Join-Path $BuildDir $RootModule)

        $Key = "FunctionsToExport"
        $Exported = $Script:Manifest | Get-ManifestValue $Key
        if ($Exported -eq '*' -or -not $Exported) {
            $PublicFunctions = $PublicFunctions | Sort-Object -Unique
            $Value = "@(`n    '$($PublicFunctions -join "',`n    '")'`n)"
            $Script:Manifest = $Script:Manifest | Update-ManifestValue $Key $Value

            Write-Build Green "Updated function export list: $($PublicFunctions -join ', ')"
        }

        $Script:Manifest | Write-Manifest -Path (Join-Path $BuildDir $ManifestFile)
    }
}

task BuildDotnet @{
    Inputs = {$DotnetProject | ForEach-Object {"$_/*.cs", "$_/*.csproj"} | Get-ChildItem -ErrorAction Ignore}
    Outputs = {$DotnetProject | ForEach-Object {"$BuildDir/$_.dll"}}
    Jobs = "BuildDir", "Includes", {
        if (-not $DotnetProject) {return}

        $DotnetProject | ForEach-Object {
            exec {dotnet build $_ --output $BuildDir}
        }
    }
}

task Build Includes, BuildDotnet, BuildPowershell

task Lint {
    $Files = $Include, $PSScriptFolder |
        Write-Output |
        Where-Object {Test-Path $_} |
        Get-ChildItem -Recurse

    $Files |
        ForEach-Object {
            Invoke-ScriptAnalyzer -Path $_.FullName -Recurse -Settings .\.vscode\PSScriptAnalyzerSettings.psd1
        } |
        Tee-Object -Variable PSSAOutput

    if ($PSSAOutput | Where-Object Severity -ge ([int][Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]::Warning))
    {
        throw "PSSA found code violations"
    }
}

task UnitTest Build, {
    [bool]$UseNewProcess = $DotnetProject

    $Run = $PesterConfiguration.Run
    if ($null -eq $Run)
    {
        $Run = $PesterConfiguration.Run = @{}
    }

    if ($TestPath)
    {
        $Run.Path = $TestPath
    }

    if ($UseNewProcess)
    {
        $Run.Exit = $true
        $PesterConfigJson = $PesterConfiguration | ConvertTo-Json -Depth 10 -Compress

        $PSPath = (Get-Process -Id $PID).Path
        $Command = $ExecutionContext.InvokeCommand.ExpandString({
            Import-Module -Global $BuiltManifest -ea Stop
            Invoke-Pester -Configuration ('$PesterConfigJson' | ConvertFrom-Json)
        })
        exec { & $PSPath -NoLogo -NoProfile -Command $Command}
    }
    else
    {
        Remove-Module $ModuleName -ea Ignore
        Import-Module -Global $BuiltManifest -ea Stop
        Invoke-Pester -Configuration $PesterConfiguration
    }
}

task Test Lint, UnitTest

task Fetch AssertGit, {
    $Script:RemoteBranch = git rev-parse --abbrev-ref --symbolic-full-name "@{upstream}"
    $Output = git fetch ($RemoteBranch -replace '/.*') *>&1
    assert $? ($Output | Out-String)
}

task Tag ReadManifest, Fetch, {
    if (git diff -- $ManifestFile)
    {
        $VersionChange = (git diff HEAD~1..HEAD) -match '^\+\s*ModuleVersion\s*=' -replace '^\+\s*'
        assert (-not $VersionChange) (
            "The last commit changed the module version: $VersionChange. " +
            "It's probably an error to increment the version in consecutive commits."
        )

        $Output = git add $ManifestFile *>&1
        assert $? ($Output | Out-String)

        $Output = git commit -m $Tag *>&1
        assert $? ($Output | Out-String)
    }

    $Output = git tag $Tag -m $Tag *>&1
    if (-not $?)
    {
        if ($Output -match 'already exists')
        {
            # If tag points to head, we don't care
            $Refs = (git show-ref $Tag --head) -replace ' .*'
            assert ($Refs[0] -eq $Refs[1]) "Tag already exists and points to $($Refs[1] -replace '(?<=^.{7}).*')"
        }
        else
        {
            Write-Build Red $Output
            assert $false
        }
    }
}

task Push Fetch, {
    $MergeBase = git merge-base HEAD $RemoteBranch
    $RemoteHead = git rev-parse $RemoteBranch
    assert ($RemoteHead -eq $MergeBase) "Remote branch is ahead"

    $Output = git push *>&1
    assert $? ($Output | Out-String)

    $Output = git push --tags *>&1
    assert $? ($Output | Out-String)
}

task Package Build, {
    Get-ChildItem $OutputFolder -File -Filter *.nupkg | Remove-Item  # PSResourceGet insists on recreating nupkg

    if (-not (Get-PSResourceRepository $ModuleName -ErrorAction Ignore))
    {
        Register-PSResourceRepository $ModuleName -Uri $OutputFolder -Trusted
    }
    try
    {
        Write-Verbose "Packaging to $OutputFolder..."
        Publish-PSResource -Path $BuildDir -Repository $ModuleName
    }
    finally
    {
        Unregister-PSResourceRepository $ModuleName
    }

    $PackageName = Get-ChildItem $OutputFolder -File -Filter *.nupkg | Select-Object -ExpandProperty Name
    $Script:PackageFile = Join-Path $OutputFolder $PackageName
}

task Zip AssertZip, Build, {
    $ZipName = "$ModuleName.$Version.zip"

    if ($IsLinux)
    {
        Push-Location $OutputFolder -ErrorAction Stop
        try
        {
            $Output = zip -or $ZipName $ModuleName *>&1
            assert $? ($Output | Out-String)
        }
        finally
        {
            Pop-Location
        }
    }
    else
    {
        throw "Not implemented"
    }

    $Script:ZipFile = Join-Path $OutputFolder $ZipName
}

task GithubRelease AssertGh, Tag, Push, Package, Zip, {
    $Output = gh release view $Tag *>&1
    if ($Output -notmatch "release not found")
    {
        $Message = if ($?) {"A release exists already for $Tag"} else {$Output | Out-String}
        assert $false $Message
    }
    $Output = gh release create $Tag --notes $Tag $ZipFile $PackageFile *>&1
    assert ($LASTEXITCODE -eq 0) ($Output | Out-String)
}

task PSGallery BuildDir, {
    if (-not $PSGalleryApiKey)
    {
        if (Get-Command rbw -ErrorAction Ignore)  # TODO: sort out SecretManagement wrapper
        {
            $PSGalleryApiKey = rbw get PSGallery
        }
    }
    assert $PSGalleryApiKey "PSGallery API key required"

    Get-ChildItem -File $OutputFolder -Filter *.nupkg | Remove-Item  # PSResourceGet insists on recreating nupkg
    Publish-PSResource -Path $BuildDir -DestinationPath $OutputFolder -Repository PSGallery -ApiKey $PSGalleryApiKey
}

task Publish GithubRelease, PSGallery

# Default task
task . Clean, Build, Test
