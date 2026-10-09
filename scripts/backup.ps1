param([ValidatePattern('^[a-z0-9-]+$')][string]$Label = 'manual')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$backupRoot = Join-Path $workspace 'backups'
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$destination = Join-Path $backupRoot "before-$Label-$stamp"
if (Test-Path -LiteralPath $destination) { throw 'Backup already exists.' }
New-Item -ItemType Directory -Path $destination | Out-Null

# Archive the actual working files, including uncommitted and untracked source.
# Build output and previous backups remain excluded by the repository ignore rules.
$files = @(git -C $workspace -c core.quotepath=false ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate source files.' }
$sourceZip = Join-Path $destination 'source.zip'
$zip = [IO.Compression.ZipFile]::Open($sourceZip, [IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($relative in $files) {
    $filePath = [IO.Path]::GetFullPath((Join-Path $workspace $relative))
    if (-not $filePath.StartsWith($workspace + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'Source path escaped the workspace.'
    }
    if (Test-Path -LiteralPath $filePath -PathType Leaf) {
      [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $filePath, $relative.Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
  }
} finally { $zip.Dispose() }

$releaseRoot = Join-Path $workspace 'build/windows/x64/runner/Release'
if (-not (Test-Path -LiteralPath (Join-Path $releaseRoot 'fusion_reader.exe'))) {
  throw 'No complete Windows release to back up. Previous backups were retained.'
}
$releaseZip = Join-Path $destination 'windows-release.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($releaseRoot, $releaseZip, [IO.Compression.CompressionLevel]::Optimal, $false)

# Read every compressed entry before removing the previous recovery copy.
foreach ($archivePath in @($sourceZip, $releaseZip)) {
  $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
  try {
    if ($archive.Entries.Count -eq 0) { throw 'Empty backup archive.' }
    foreach ($entry in $archive.Entries) {
      $stream = $entry.Open()
      try { $stream.CopyTo([IO.Stream]::Null) } finally { $stream.Dispose() }
    }
    $required = if ($archivePath -eq $sourceZip) { 'lib/models/models.dart' } else { 'fusion_reader.exe' }
    if ($null -eq $archive.GetEntry($required)) { throw 'Incomplete backup archive.' }
  } finally { $archive.Dispose() }
}
$manifest = @{
  created = $stamp
  purpose = "Before $Label"
  commit = (git -C $workspace rev-parse HEAD)
  retention = 'latest complete backup only'
  sourceSha256 = (Get-FileHash -LiteralPath $sourceZip -Algorithm SHA256).Hash
  windowsSha256 = (Get-FileHash -LiteralPath $releaseZip -Algorithm SHA256).Hash
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'backup.json') -Encoding utf8

$freed = [long]0
foreach ($old in Get-ChildItem -LiteralPath $backupRoot -Directory) {
  if ($old.FullName -eq $destination) { continue }
  # Remove only generated, complete backups directly within this workspace.
  $resolved = [IO.Path]::GetFullPath($old.FullName)
  if ([IO.Path]::GetDirectoryName($resolved) -ne $backupRoot -or
      $old.Name -notmatch '^before-[a-z0-9-]+-\d{8}-\d{6}$' -or
      ($old.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
      -not (Test-Path -LiteralPath (Join-Path $resolved 'backup.json')) -or
      -not (Test-Path -LiteralPath (Join-Path $resolved 'source.zip')) -or
      -not (Test-Path -LiteralPath (Join-Path $resolved 'windows-release.zip'))) {
    continue
  }
  $freed += (Get-ChildItem -LiteralPath $resolved -Recurse -File | Measure-Object -Property Length -Sum).Sum
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
[PSCustomObject]@{
  Backup = $destination
  SizeMB = [Math]::Round(((Get-Item -LiteralPath $sourceZip).Length + (Get-Item -LiteralPath $releaseZip).Length) / 1MB, 1)
  RemovedOldBackupMB = [Math]::Round($freed / 1MB, 1)
}
