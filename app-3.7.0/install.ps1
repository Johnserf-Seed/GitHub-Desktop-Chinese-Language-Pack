[CmdletBinding()]
param([string]$AppPath, [switch]$CheckOnly, [string]$PackagePath)
. (Join-Path $PSScriptRoot 'package-common.ps1')

$PackageRoot = Get-PackageDirectory $PackagePath $AppPath
$manifest = Get-PatchManifest
if ($PackageRoot -ne $PSScriptRoot) { Write-Host "使用翻译包：$PackageRoot" }
$appDirectory = Get-AppDirectory $AppPath $manifest
Assert-AppClosed $appDirectory
$patchLock = $null
try {
if (-not $CheckOnly) { $patchLock = Enter-PatchLock $appDirectory }
$backupDirectory = Join-Path $appDirectory '.zh-cn-backup'
$states = @{}
foreach ($file in $PatchFiles) {
    $patch = Join-Path $PackageRoot "resources\app\$file"
    if ((Get-FileDigest $patch) -ne $manifest.files.$file.translatedSha256) { throw "翻译文件已更改或损坏：$file。" }
    $states[$file] = Get-FileDigest (Join-Path $appDirectory $file)
    if ($states[$file] -ne $manifest.files.$file.originalSha256 -and $states[$file] -ne $manifest.files.$file.translatedSha256) {
        if ((Test-Path -LiteralPath $backupDirectory) -and $states[$file] -eq (Get-SavedTranslationDigest $backupDirectory $file)) { throw '当前安装了另一版汉化。请先运行 restore.cmd 恢复原版，再安装新包。' }
        throw "当前文件与此翻译包不匹配：$file。请使用相同版本的原版文件重新生成。"
    }
}
if (Test-Path -LiteralPath $backupDirectory) { Assert-Backup $backupDirectory $manifest }
elseif (@($PatchFiles | Where-Object { $states[$_] -ne $manifest.files.$_.originalSha256 }).Count -gt 0) { throw '找不到有效的原版备份，已停止操作。' }
if ($CheckOnly) { Write-Host '校验通过，未安装，也未修改任何程序文件。'; return }
if (@($PatchFiles | Where-Object { $states[$_] -ne $manifest.files.$_.translatedSha256 }).Count -eq 0) { Write-Host '此版本已安装相同汉化包。'; return }
if (-not (Test-Path -LiteralPath $backupDirectory)) {
    # Create a complete, verified backup before replacing either program file.
    $temporaryBackup = Join-Path $appDirectory ('.zh-cn-backup-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryBackup | Out-Null
    foreach ($file in $PatchFiles) { Copy-Item -LiteralPath (Join-Path $appDirectory $file) -Destination (Join-Path $temporaryBackup $file) }
    @{version=$manifest.version; files=$manifest.files} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $temporaryBackup 'backup-manifest.json') -Encoding UTF8
    Assert-Backup $temporaryBackup $manifest
    [IO.Directory]::Move($temporaryBackup, $backupDirectory)
}
try {
    foreach ($file in $PatchFiles) {
        Set-FileAtomically (Join-Path $PackageRoot "resources\app\$file") (Join-Path $appDirectory $file)
        if ((Get-FileDigest (Join-Path $appDirectory $file)) -ne $manifest.files.$file.translatedSha256) { throw "安装后校验失败：$file。" }
    }
    Save-BackupManifest $backupDirectory $manifest
} catch {
    $failure = $_.Exception.Message
    $rollbackProblems = @()
    foreach ($file in $PatchFiles) {
        try {
            if ((Get-FileDigest (Join-Path $appDirectory $file)) -ne $manifest.files.$file.originalSha256) {
                Set-FileAtomically (Join-Path $backupDirectory $file) (Join-Path $appDirectory $file)
            }
            if ((Get-FileDigest (Join-Path $appDirectory $file)) -ne $manifest.files.$file.originalSha256) { throw '恢复校验失败。' }
        } catch { $rollbackProblems += $file }
    }
    if ($rollbackProblems.Count -gt 0) { throw "安装失败，部分文件未能恢复：$($rollbackProblems -join ', ')。原版备份：$backupDirectory" }
    throw "安装失败，已恢复原文件：$failure"
}
Write-Host "GitHub Desktop $($manifest.version) 汉化已安装。现在可以重新启动程序。"
Write-Host "原版备份：$backupDirectory"
} finally { if ($null -ne $patchLock) { $patchLock.Dispose() } }
