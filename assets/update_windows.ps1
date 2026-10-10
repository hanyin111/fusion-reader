param([Parameter(Mandatory=$true)][string]$ConfigPath, [switch]$SkipLaunch)
$ErrorActionPreference = 'Stop'
$configPathFull = [IO.Path]::GetFullPath($ConfigPath)
$job = [IO.Path]::GetDirectoryName($configPathFull)
$config = Get-Content -LiteralPath $configPathFull -Raw -Encoding UTF8 | ConvertFrom-Json
$install = [IO.Path]::GetFullPath($config.installDirectory).TrimEnd('\')
$payload = Join-Path $job 'payload'
$rollback = Join-Path $job 'rollback'
$installedExe = Join-Path $install 'fusion_reader.exe'
$resultPath = Join-Path $job 'result.json'
$changed = [Collections.Generic.List[string]]::new()
$original = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function ChildPath([string]$root, [string]$relative) {
  $full = [IO.Path]::GetFullPath((Join-Path $root $relative))
  if (-not $full.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Update path escaped its intended directory.'
  }
  return $full
}
function CheckLinks([string]$root, [string]$target) {
  $current = $target
  while ($current.Length -ge $root.Length) {
    if ((Test-Path -LiteralPath $current) -and
        ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw 'Update paths must not contain links.'
    }
    if ($current -eq $root) { break }
    $current = [IO.Path]::GetDirectoryName($current)
  }
}
function SaveResult([string]$status, [string]$message) {
  @{status=$status;message=$message} | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
}
function HashFile([string]$path) {
  $hash = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($path)
  try { return [BitConverter]::ToString($hash.ComputeHash($stream)) }
  finally { $stream.Dispose(); $hash.Dispose() }
}

try {
  if ($install -eq [IO.Path]::GetPathRoot($install).TrimEnd('\') -or
      -not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
    throw 'The installed application directory is invalid.'
  }
  CheckLinks $install $installedExe
  foreach ($required in @('fusion_reader.exe', 'flutter_windows.dll', 'data\app.so')) {
    if (-not (Test-Path -LiteralPath (ChildPath $payload $required) -PathType Leaf)) {
      throw 'Update bundle is incomplete.'
    }
  }
  if ([int]$config.processId -gt 0) {
    $runningProcess = Get-Process -Id ([int]$config.processId) -ErrorAction SilentlyContinue
    if ($null -ne $runningProcess) {
      if ($runningProcess.Path -ne $installedExe) { throw 'The application process does not match.' }
      if (-not $runningProcess.WaitForExit(60000)) { throw 'The application did not close in time.' }
    }
  }
  $files = @(Get-ChildItem -LiteralPath $payload -Recurse -File | Sort-Object FullName)
  # Copy existing files before changing any of them. The rollback folder is
  # inside this updater's job, never in the application's user data directory.
  foreach ($file in $files) {
    $relative = $file.FullName.Substring($payload.Length + 1)
    $destination = ChildPath $install $relative
    CheckLinks $payload $file.FullName
    CheckLinks $install $destination
    if (Test-Path -LiteralPath $destination) {
      if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw 'An update file conflicts with an existing directory.' }
      $saved = ChildPath $rollback $relative
      New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($saved)) -Force | Out-Null
      Copy-Item -LiteralPath $destination -Destination $saved -Force
      $original.Add($relative) | Out-Null
    }
  }
  foreach ($file in $files) {
    $relative = $file.FullName.Substring($payload.Length + 1)
    $destination = ChildPath $install $relative
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
    $changed.Add($relative)
    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
  }
  SaveResult 'complete' 'Update installed.'
  if (-not $SkipLaunch) {
    # Reopen the interactive app; the updater itself runs with no console.
    Start-Process -FilePath $installedExe -WorkingDirectory $install -WindowStyle Normal
  }
} catch {
  $failure = $_.Exception.Message
  $restored = $true
  $rollbackError = ''
  foreach ($relative in $changed) {
    try {
      $destination = ChildPath $install $relative
      if ($original.Contains($relative)) {
        $saved = ChildPath $rollback $relative
        # A locked file may have failed before any bytes were changed. Avoid
        # treating that unchanged original as a failed rollback.
        if ((Test-Path -LiteralPath $destination -PathType Leaf) -and
            (HashFile $destination) -eq (HashFile $saved)) { continue }
        Copy-Item -LiteralPath $saved -Destination $destination -Force
      } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
        Remove-Item -LiteralPath $destination -Force
      }
    } catch { $restored = $false; $rollbackError = $_.Exception.Message }
  }
  SaveResult 'failed' "$failure; rollback=$restored; $rollbackError"
  if (-not $SkipLaunch) {
    Add-Type -AssemblyName System.Windows.Forms
    $message = if ($restored) { '更新未完成，原版本已保留。请稍后重试。' } else { '更新未完成。请从 GitHub 下载完整 Windows 包，解压到新的文件夹运行。' }
    [Windows.Forms.MessageBox]::Show($message, '聚阅更新') | Out-Null
    if ($restored) { Start-Process -FilePath $installedExe -WorkingDirectory $install -WindowStyle Normal }
  }
  exit 1
}
