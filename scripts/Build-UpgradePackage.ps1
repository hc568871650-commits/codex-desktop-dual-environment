param([string]$Version='0.2.0')
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Upgrade.ps1"
$root=Split-Path $PSScriptRoot -Parent
$archive=Join-Path $root "dist\CodexDualLauncher-0.1-to-$Version-upgrade.zip"
if(Test-Path -LiteralPath $archive){throw '升级包已存在，不覆盖。'}
[void][IO.Directory]::CreateDirectory((Split-Path $archive -Parent))
$files=@('.gitignore','version.json','Start.cmd','Install.cmd','Controller.cmd','Uninstall.cmd','Configure.cmd','Upgrade.cmd','Rollback.cmd','src','scripts','assets','config','docs','README.md')|ForEach-Object{Join-Path $root $_}
[void](Get-UpgradePayload $root)
Compress-Archive -LiteralPath $files -DestinationPath $archive
Get-FileHash -LiteralPath $archive -Algorithm SHA256 | Format-List
