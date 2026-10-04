Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PackageScriptDirectory = $PSScriptRoot
$PatchFiles = @('main.js', 'renderer.js')

function Resolve-AppDirectory([string]$RequestedPath) {
    if ([string]::IsNullOrWhiteSpace($RequestedPath)) { $RequestedPath = Join-Path $env:LOCALAPPDATA 'GitHubDesktop' }
    if (-not (Test-Path -LiteralPath $RequestedPath -PathType Container)) { throw "找不到 GitHub Desktop 目录：$RequestedPath" }
    $resolved = (Resolve-Path -LiteralPath $RequestedPath).ProviderPath
    if (-not (Test-Path -LiteralPath (Join-Path $resolved 'package.json') -PathType Leaf)) {
        if (Test-Path -LiteralPath (Join-Path $resolved 'resources\app\package.json') -PathType Leaf) {
            $resolved = Join-Path $resolved 'resources\app'
        } else {
            $versions = @(Get-ChildItem -LiteralPath $resolved -Directory | Where-Object { $_.Name -match '^app-\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name.Substring(4) } -Descending)
            if ($versions.Count -eq 0) { throw "找不到 GitHub Desktop 正式版，请使用 -AppPath 指定版本目录。" }
            $resolved = Join-Path $versions[0].FullName 'resources\app'
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $resolved 'package.json') -PathType Leaf)) { throw "目录中缺少 GitHub Desktop 版本信息：$resolved" }
    $metadata = Get-Content -LiteralPath (Join-Path $resolved 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($metadata.name -ne 'desktop' -or $metadata.productName -ne 'GitHub Desktop' -or $metadata.version -notmatch '^\d+\.\d+\.\d+$') { throw '指定目录不是支持的 GitHub Desktop 正式版。' }
    return (Resolve-Path -LiteralPath $resolved).ProviderPath
}

function Get-PackageDirectory([string]$RequestedPackage, [string]$RequestedApp) {
    if (-not [string]::IsNullOrWhiteSpace($RequestedPackage)) {
        if (-not (Test-Path -LiteralPath (Join-Path $RequestedPackage 'manifest.json') -PathType Leaf)) { throw '指定目录中没有 manifest.json，请将 -PackagePath 指向已解压的翻译包目录。' }
        return (Resolve-Path -LiteralPath $RequestedPackage).ProviderPath
    }
    if (Test-Path -LiteralPath (Join-Path $PackageScriptDirectory 'manifest.json') -PathType Leaf) { return $PackageScriptDirectory }

    # Project entry points select a generated package for the requested installed version.
    $appDirectory = Resolve-AppDirectory $RequestedApp
    $metadata = Get-Content -LiteralPath (Join-Path $appDirectory 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $projectDirectory = Split-Path -Parent $PackageScriptDirectory
    foreach ($directory in @((Join-Path $projectDirectory 'dist'), $projectDirectory)) {
        $candidate = Join-Path $directory "app-$($metadata.version)"
        if (Test-Path -LiteralPath (Join-Path $candidate 'manifest.json') -PathType Leaf) { return $candidate }
    }
    throw "找不到适用于 GitHub Desktop $($metadata.version) 的翻译包。请先运行 generate.cmd，或使用 -PackagePath 指定已解压的包目录。"
}

function Get-PatchManifest {
    $manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.product -ne 'GitHub Desktop' -or $manifest.locale -ne 'zh-CN' -or $manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw '翻译包清单无效。' }
    foreach ($file in $PatchFiles) {
        if ($null -eq $manifest.files.$file -or $manifest.files.$file.originalSha256 -notmatch '^[a-f0-9]{64}$' -or $manifest.files.$file.translatedSha256 -notmatch '^[a-f0-9]{64}$') { throw "文件校验值无效：$file" }
    }
    return $manifest
}

function Get-AppDirectory([string]$RequestedPath, $Manifest) {
    if ([string]::IsNullOrWhiteSpace($RequestedPath)) { $RequestedPath = Join-Path $env:LOCALAPPDATA "GitHubDesktop\app-$($Manifest.version)\resources\app" }
    $resolved = Resolve-AppDirectory $RequestedPath
    $metadata = Get-Content -LiteralPath (Join-Path $resolved 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($metadata.name -ne 'desktop' -or $metadata.productName -ne 'GitHub Desktop' -or $metadata.version -ne $Manifest.version) { throw "版本不匹配。本包只适用于 GitHub Desktop $($Manifest.version)。" }
    return $resolved
}

function Assert-AppClosed([string]$AppDirectory) {
    $installation = Split-Path -Parent (Split-Path -Parent $AppDirectory)
    foreach ($process in @(Get-Process -Name GitHubDesktop -ErrorAction SilentlyContinue)) {
        try { $processPath = $process.Path } catch { $processPath = $null }
        if ([string]::IsNullOrWhiteSpace($processPath) -or $processPath.StartsWith($installation + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'GitHub Desktop 正在运行。请正常退出后再执行此操作。' }
    }
}

function Get-FileDigest([string]$FilePath) {
    return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Enter-PatchLock([string]$AppDirectory) {
    try { return [IO.File]::Open((Join-Path $AppDirectory '.zh-cn.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw '另一个汉化安装或恢复操作正在进行，请稍后重试。' }
}

function Assert-Backup([string]$Directory, $Manifest) {
    $backupManifest = Get-Content -LiteralPath (Join-Path $Directory 'backup-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($backupManifest.version -ne $Manifest.version) { throw '备份版本不匹配。' }
    foreach ($file in $PatchFiles) {
        if ((Get-FileDigest (Join-Path $Directory $file)) -ne $Manifest.files.$file.originalSha256) { throw "原版备份校验失败：$file。已停止操作。" }
    }
}

function Get-SavedTranslationDigest([string]$Directory, [string]$File) {
    $record = Get-Content -LiteralPath (Join-Path $Directory 'backup-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $files = $record.PSObject.Properties['files']
    if ($null -eq $files) { return $null }
    $entry = $files.Value.PSObject.Properties[$File]
    if ($null -eq $entry) { return $null }
    $digest = $entry.Value.PSObject.Properties['translatedSha256']
    if ($null -eq $digest -or $digest.Value -notmatch '^[a-f0-9]{64}$') { return $null }
    return $digest.Value
}

function Save-BackupManifest([string]$Directory, $Manifest) {
    $target = Join-Path $Directory 'backup-manifest.json'
    $temporary = $target + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $record = @{ version = $Manifest.version; files = $Manifest.files } | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($temporary, $record, [Text.UTF8Encoding]::new($true))
        Set-FileAtomically $temporary $target
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Set-FileAtomically([string]$Source, [string]$Target) {
    $temporary = $Target + '.zh-cn-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        [IO.File]::Replace($temporary, $Target, [NullString]::Value)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}
