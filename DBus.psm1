#region build-inlines
Get-ChildItem $PSScriptRoot -Directory
    | ? Name -in ("Public", "Private")
    | Get-ChildItem -File -Recurse -Filter *.ps1
    | % {. $_}
#endregion build-inlines
