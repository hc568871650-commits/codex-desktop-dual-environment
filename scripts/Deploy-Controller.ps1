param(
 [Parameter(Mandatory=$true)][string]$ConfigPath,
 [Parameter(Mandatory=$true)][string]$Destination,
 [string]$DisplayName='Codex 双环境',
 [string]$ShortcutDirectory
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
$config=Read-ControllerConfig $ConfigPath
$root=Get-FullDirectory $Destination;Assert-NoReparsePoint $root
if((Test-Path -LiteralPath $root) -and @(Get-ChildItem -LiteralPath $root -Force).Count){throw '部署目标必须为空，现有文件不会覆盖。'}
foreach($instance in $config.instances){foreach($key in @('home','profile','projects','projectless')){if($instance.$key -and (Test-PathOverlap $root $instance.$key)){throw '工具目录必须与用户数据目录分离。'}}}
if(-not $ShortcutDirectory){$ShortcutDirectory=$root}
$ShortcutDirectory=Get-FullDirectory $ShortcutDirectory;Assert-NoReparsePoint $ShortcutDirectory
$shortcutPath=Join-Path $ShortcutDirectory 'Codex 双环境.lnk'
if(Test-Path -LiteralPath $shortcutPath){throw '同名快捷方式已存在，保留原文件。'}
$source=Split-Path $PSScriptRoot -Parent
$config.stateDirectory=Join-Path $root 'state'
$config|Add-Member NoteProperty displayName $DisplayName -Force
$manifest=[ordered]@{schema=1;root=$root;files=@();shortcuts=@();retainedData=@($config.instances.home);created=[DateTime]::UtcNow.ToString('o')}
[void][IO.Directory]::CreateDirectory($root)
function Save-DeploymentManifest {Write-AtomicText (Join-Path $root 'install-manifest.json') ($manifest|ConvertTo-Json -Depth 6)}
Save-DeploymentManifest
foreach($part in @('.gitignore','version.json','src','assets','scripts','config','docs','README.md','Start.cmd','Install.cmd','Configure.cmd','Upgrade.cmd','Rollback.cmd','Controller.cmd','Uninstall.cmd')){
 $path=Join-Path $source $part
 $items=if(Test-Path -LiteralPath $path -PathType Container){@(Get-ChildItem -LiteralPath $path -File -Recurse)}else{@(Get-Item -LiteralPath $path)}
 foreach($item in $items){$relative=$item.FullName.Substring($source.Length+1);$target=Join-Path $root $relative
  [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent));[IO.File]::Copy($item.FullName,$target,$false)
  $manifest.files+=@{path=$relative;sha256=(Get-FileHash -LiteralPath $target).Hash};Save-DeploymentManifest
 }
}
$destinationConfig=Join-Path $root 'instances.local.json'
Write-AtomicText $destinationConfig ($config|ConvertTo-Json -Depth 8)
[void](Read-ControllerConfig $destinationConfig)
$hostPath=Join-Path $root 'CodexDualController.exe'
& "$PSScriptRoot\Build-ControllerHost.ps1" -Destination $hostPath | Out-Null
$manifest.files+=@{path='CodexDualController.exe';sha256=(Get-FileHash -LiteralPath $hostPath).Hash};Save-DeploymentManifest
[void][IO.Directory]::CreateDirectory($ShortcutDirectory)
$shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($shortcutPath)
$link.TargetPath=$hostPath
$link.Arguments=''
$link.WorkingDirectory=$root;$link.IconLocation=Join-Path $root 'assets\controller.ico';$link.Save()
$manifest.shortcuts+=@{path=$shortcutPath;sha256=(Get-FileHash -LiteralPath $shortcutPath).Hash};Save-DeploymentManifest
Write-Output $shortcutPath
