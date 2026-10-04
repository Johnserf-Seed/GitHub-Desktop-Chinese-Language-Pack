[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$source = & (Join-Path $PSScriptRoot 'download-latest.ps1')
& (Join-Path $PSScriptRoot 'generate.ps1') -AppPath $source.AppPath -OutputDirectory $OutputDirectory
