[CmdletBinding()]
param([string]$AppPath, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$nodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue
$nodeCandidates = @()
if ($null -ne $nodeCommand) { $nodeCandidates += $nodeCommand.Source }
$nodeCandidates += @(
    (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'),
    (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe')
)
$nodeExecutable = $null
foreach ($candidate in $nodeCandidates | Select-Object -Unique) {
    if (Test-Path -LiteralPath $candidate) {
        $version = & $candidate --version
        if ($LASTEXITCODE -eq 0 -and $version -match '^v(\d+)\.' -and [int]$Matches[1] -ge 22) { $nodeExecutable = $candidate; break }
    }
}
if ($null -eq $nodeExecutable) { throw '请安装 Node.js 22 或更高版本，再重新生成。' }
$arguments = @((Join-Path $PSScriptRoot 'generate.cjs'))
if ($AppPath) { $arguments += @('--app', $AppPath) }
if ($OutputDirectory) { $arguments += @('--output', $OutputDirectory) }
$previousEncoding = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    & $nodeExecutable @arguments
    if ($LASTEXITCODE -ne 0) { throw '翻译包生成失败。' }
} finally { [Console]::OutputEncoding = $previousEncoding }
$output = Join-Path $project 'dist'
if ($OutputDirectory) { $output = $OutputDirectory }
foreach ($directory in @(Get-ChildItem -LiteralPath $output -Directory -Filter 'app-*')) {
    $zip = Join-Path $output "GitHubDesktop-$($directory.Name.Substring(4))-zh-CN.zip"
    Compress-Archive -LiteralPath $directory.FullName -DestinationPath $zip -Force
    Write-Host "压缩包：$zip"
}
