param([string]$InstallDirectory=(Split-Path $PSScriptRoot -Parent),[switch]$Apply)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
$root=Get-FullDirectory $InstallDirectory;Assert-NoReparsePoint $root
$manifest=Get-Content -LiteralPath (Join-Path $root 'install-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($manifest.schema -ne 1 -or $manifest.root -ne $root){throw 'Installation ownership mismatch.'}
$exe=Join-Path $root 'CodexDualController.exe'
if(@(Get-CimInstance Win32_Process -Filter "Name='CodexDualController.exe'"|Where-Object {$_.ExecutablePath -eq $exe}).Count){throw 'Exit this controller before uninstalling.'}
$remove=@();$preserved=@()
foreach($entry in $manifest.files){
 if([IO.Path]::IsPathRooted($entry.path) -or $entry.path -match '(^|[\\/])(state|sessions|Credentials|CodexHome|DesktopProfile|backups|upgrades)([\\/]|$)' -or $entry.path -match '(\.local\.json|\.dpapi)$'){throw 'Invalid tool ownership entry.'}
 $path=[IO.Path]::GetFullPath((Join-Path $root $entry.path));Assert-NoReparsePoint $path
 if(-not $path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Ownership path escaped installation.'}
 if(Test-Path -LiteralPath $path){if((Get-FileHash -LiteralPath $path).Hash -eq $entry.sha256){$remove+=$path}else{$preserved+=$path}}
}
foreach($entry in $manifest.shortcuts){
 $path=[IO.Path]::GetFullPath($entry.path);Assert-NoReparsePoint $path
 if([IO.Path]::GetExtension($path) -ne '.lnk'){throw 'Invalid shortcut ownership entry.'}
 if(Test-Path -LiteralPath $path){if((Get-FileHash -LiteralPath $path).Hash -eq $entry.sha256){$remove+=$path}else{$preserved+=$path}}
}
if($Apply){
 $config=Join-Path $root 'instances.local.json';$name=Get-ControllerStartupName $config
 $startup=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
 if($startup -and $startup.PSObject.Properties[$name] -and [string]$startup.$name -in @((Get-ControllerStartupCommand $root $config),(Get-LegacyControllerStartupCommand $root $config))){Set-ControllerAutoStart $root $config $false}
 foreach($path in $remove){[IO.File]::Delete($path)}
}
@{applied=[bool]$Apply;toolFiles=$remove.Count;preserved=$preserved;userDataRetained=$true}|ConvertTo-Json -Depth 4
