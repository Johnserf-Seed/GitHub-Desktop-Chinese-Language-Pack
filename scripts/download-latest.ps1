[CmdletBinding()]
param([string]$Destination = (Join-Path (Split-Path -Parent $PSScriptRoot) 'work\upstream'))
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$downloadUrl = 'https://central.github.com/deployments/desktop/desktop/latest/win32'
$sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
if ($sevenZip) { $sevenZipPath = $sevenZip.Source }
else { $sevenZipPath = Join-Path $env:ProgramFiles '7-Zip\7z.exe' }
if (-not (Test-Path -LiteralPath $sevenZipPath)) { throw '请安装 7-Zip 后再下载生成，或使用本机已安装版本生成。' }
$downloadRoot = Join-Path ([IO.Path]::GetFullPath($Destination)) ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
$installer = Join-Path $downloadRoot 'GitHubDesktopSetup-x64.exe'
Write-Host '正在下载 GitHub 官方 Windows x64 正式版安装包（仅解包，不安装）…'
Invoke-WebRequest -Uri $downloadUrl -OutFile $installer -UseBasicParsing -TimeoutSec 300
$installerDigest = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
$setupDirectory = Join-Path $downloadRoot 'setup'
& $sevenZipPath x $installer "-o$setupDirectory" -y | Out-Null
if ($LASTEXITCODE -ne 0) { throw '官方安装包解包失败。' }
$packages = @(Get-ChildItem -LiteralPath $setupDirectory -Recurse -File -Filter '*-full.nupkg')
if ($packages.Count -ne 1) { throw '未找到唯一的完整程序包。官方安装格式可能已更改，请使用本机版本生成。' }
$applicationDirectory = Join-Path $downloadRoot 'application'
& $sevenZipPath x $packages[0].FullName "-o$applicationDirectory" -y | Out-Null
if ($LASTEXITCODE -ne 0) { throw '完整程序包解包失败。' }
$apps = @(Get-ChildItem -LiteralPath $applicationDirectory -Recurse -File -Filter 'package.json' | Where-Object {
    (Test-Path -LiteralPath (Join-Path $_.DirectoryName 'renderer.js')) -and (Test-Path -LiteralPath (Join-Path $_.DirectoryName 'main.js'))
})
if ($apps.Count -ne 1) { throw '未找到唯一的界面目录。' }
$appDirectory = $apps[0].DirectoryName
$metadata = Get-Content -LiteralPath $apps[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
if ($metadata.name -ne 'desktop' -or $metadata.productName -ne 'GitHub Desktop' -or $metadata.version -notmatch '^\d+\.\d+\.\d+$') { throw '下载结果不是支持的 GitHub Desktop 正式版。' }
foreach ($file in 'main.js.map', 'renderer.js.map') { if (-not (Test-Path -LiteralPath (Join-Path $appDirectory $file))) { throw "官方程序包缺少 $file，已停止生成。" } }
@{url=$downloadUrl; installerSha256=$installerDigest; version=$metadata.version} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $appDirectory 'zh-cn-source.json') -Encoding UTF8
Write-Host "已解包 GitHub Desktop $($metadata.version)：$appDirectory"
[pscustomobject]@{Version=$metadata.version; AppPath=$appDirectory}
