param([string]$Version = '0.3.0')
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$') { throw 'Invalid version.' }
$repository = Split-Path $PSScriptRoot -Parent
$outputDirectory = Join-Path $repository 'dist'
[void][IO.Directory]::CreateDirectory($outputDirectory)
$archive = Join-Path $outputDirectory "CodexDualLauncher-$Version-windows.zip"
if (Test-Path -LiteralPath $archive) { throw 'Archive already exists; use a new version or move it aside.' }
$files = @('.gitignore','.github','version.json','Start.cmd','Install.cmd','Controller.cmd','Uninstall.cmd','Configure.cmd','Upgrade.cmd','Rollback.cmd','src','scripts','assets','config','tests','README.md','docs') | ForEach-Object { Join-Path $repository $_ }
Compress-Archive -LiteralPath $files -DestinationPath $archive
Get-FileHash -LiteralPath $archive -Algorithm SHA256 | Format-List
