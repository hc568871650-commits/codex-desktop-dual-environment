param([string]$DotNet='dotnet',[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$output=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $output){throw 'Release output must be new.'}
[void][IO.Directory]::CreateDirectory($output)
$package=Join-Path $output 'package'
& "$PSScriptRoot\Build-DotNet.ps1" -DotNet $DotNet -OutputDirectory $package -SelfContained
$version=Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw -Encoding UTF8|ConvertFrom-Json
foreach($folder in @('src','assets')){
 $destination=Join-Path $package $folder;[void][IO.Directory]::CreateDirectory($destination)
 Get-ChildItem -LiteralPath (Join-Path $root $folder) -Force|Copy-Item -Destination $destination -Recurse -Force
}
[void][IO.Directory]::CreateDirectory((Join-Path $package 'scripts'))
foreach($name in @('Install.ps1','DotNet-Package.ps1','Bootstrap-DotNet.ps1','Install-DotNetLocal.ps1','Rollback-DotNetLocal.ps1','Uninstall-DotNet.ps1','Set-DotNetTitle.ps1')){
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $package ('scripts\'+$name))
}
[void][IO.Directory]::CreateDirectory((Join-Path $package 'docs'))
foreach($name in @('DOTNET-INSTALL.md',('RELEASE-'+$version.version+'.md'))){Copy-Item -LiteralPath (Join-Path $root ('docs\'+$name)) -Destination (Join-Path $package ('docs\'+$name))}
Copy-Item -LiteralPath (Join-Path $root 'docs\DOTNET-INSTALL.md') -Destination (Join-Path $package 'README.md')
$license=Join-Path $root 'LICENSE';if(Test-Path -LiteralPath $license){Copy-Item -LiteralPath $license -Destination $package}
$commands=@{
 'Start.cmd'='if exist "%~dp0instances.local.json" (start "" "%~dp0CodexDualController.exe" --config "%~dp0instances.local.json") else (powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\Bootstrap-DotNet.ps1" %*)'
 'Install.cmd'='powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\Bootstrap-DotNet.ps1" %*'
 'Upgrade.cmd'='powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\Bootstrap-DotNet.ps1" %*'
 'Uninstall.cmd'='powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\Uninstall-DotNet.ps1" -Apply %*'
 'Rollback.cmd'='powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\Rollback-DotNetLocal.ps1" %*'
}
foreach($name in $commands.Keys){[IO.File]::WriteAllText((Join-Path $package $name),('@echo off'+"`r`n"+$commands[$name]+"`r`nif errorlevel 1 pause`r`n"),[Text.Encoding]::ASCII)}
$files=@(Get-ChildItem -LiteralPath $package -File -Recurse|Where-Object {$_.Name -ne 'dotnet-manifest.json'}|ForEach-Object {@{path=$_.FullName.Substring($package.Length+1);sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
@{schema=1;version=$version.version;selfContained=$true;files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $package 'dotnet-manifest.json') -Encoding UTF8
. "$PSScriptRoot\DotNet-Package.ps1"
[void](Read-DotNetPackage $package)
$zip=Join-Path $output ('CodexDualController-'+$version.version+'-win-x64.zip')
Compress-Archive -Path (Join-Path $package '*') -DestinationPath $zip
((Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant()+'  '+[IO.Path]::GetFileName($zip))|Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Encoding ASCII
Write-Output $zip
