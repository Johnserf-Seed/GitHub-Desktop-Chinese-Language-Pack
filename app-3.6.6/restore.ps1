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
Assert-Backup $backupDirectory $manifest
foreach ($file in $PatchFiles) {
    $current = Get-FileDigest (Join-Path $appDirectory $file)
    if ($current -ne $manifest.files.$file.originalSha256 -and $current -ne $manifest.files.$file.translatedSha256 -and $current -ne (Get-SavedTranslationDigest $backupDirectory $file)) { throw "当前文件包含本包以外的更改，已停止恢复：$file。" }
}
if ($CheckOnly) { Write-Host '原版备份校验通过，未修改任何程序文件。'; return }
foreach ($file in $PatchFiles) {
    Set-FileAtomically (Join-Path $backupDirectory $file) (Join-Path $appDirectory $file)
    if ((Get-FileDigest (Join-Path $appDirectory $file)) -ne $manifest.files.$file.originalSha256) { throw "恢复后校验失败：$file。" }
}
Write-Host "GitHub Desktop $($manifest.version) 已恢复原版。备份已保留。"
} finally { if ($null -ne $patchLock) { $patchLock.Dispose() } }
