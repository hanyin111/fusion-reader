param(
    [string]$Python = 'python',
    [switch]$SkipInstall
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $projectRoot 'build/admin'
$venvRoot = Join-Path $projectRoot 'build/admin-venv'
$venvPython = Join-Path $venvRoot 'Scripts/python.exe'
Set-Location -LiteralPath $projectRoot
if (-not (Test-Path -LiteralPath $venvPython)) {
    & $Python -m venv $venvRoot
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create the admin build environment.' }
}
if (-not $SkipInstall) {
    & $venvPython -m pip install --disable-pip-version-check -r admin/requirements.txt
    if ($LASTEXITCODE -ne 0) { throw 'Cannot install the admin build dependencies.' }
}
& $venvPython -m unittest discover -s admin -p 'test_*.py'
if ($LASTEXITCODE -ne 0) { throw 'Admin tests failed.' }
& $venvPython -m PyInstaller --noconfirm --clean --onefile --windowed `
    --name FusionReader-Admin --distpath $outputRoot `
    --workpath build/admin-work --specpath build/admin-spec `
    --paths admin admin/manager.py
if ($LASTEXITCODE -ne 0) { throw 'Admin packaging failed.' }
$exe = Join-Path $outputRoot 'FusionReader-Admin.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw 'The admin executable was not produced.' }
Write-Output $exe
