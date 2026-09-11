param(
 [Parameter(Mandatory=$true)][string]$OfficialHome,
 [string]$OfficialProfile='',
 [Parameter(Mandatory=$true)][string]$OfficialProjects,
 [Parameter(Mandatory=$true)][string]$OfficialProjectless,
 [Parameter(Mandatory=$true)][string]$ApiRoot,
 [Parameter(Mandatory=$true)][string]$ApiLauncher,
 [string]$Executable='',
 [Parameter(Mandatory=$true)][string]$ConfigPath
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
$target=Get-FullDirectory $ConfigPath;Assert-NoReparsePoint $target
if(Test-Path -LiteralPath $target){throw '目标配置已存在，不覆盖。'}
$api=Get-FullDirectory $ApiRoot
$config=[pscustomobject]@{schema=1;stateDirectory=(Join-Path (Split-Path $target -Parent) 'state');instances=@(
 [pscustomobject]@{id=[Guid]::NewGuid().ToString('N');role='official';home=$OfficialHome;profile=$OfficialProfile;projects=$OfficialProjects;projectless=$OfficialProjectless;launchMode='official';executable=$Executable},
 [pscustomobject]@{id=[Guid]::NewGuid().ToString('N');role='api';home=(Join-Path $api 'CodexHome');profile=(Join-Path $api 'DesktopProfile');projects=(Join-Path $api 'Projects');projectless=(Join-Path $api 'Projectless');launchMode='external';externalLauncher=$ApiLauncher;executable=$Executable}
)}
foreach($i in $config.instances){foreach($key in @('home','projects','projectless')){if(-not (Test-Path -LiteralPath $i.$key -PathType Container)){throw "已有环境缺少 $key 目录。"}}}
if(-not (Test-Path -LiteralPath $ApiLauncher -PathType Leaf) -or [IO.Path]::GetExtension($ApiLauncher) -ne '.ps1'){throw '需要现有 PowerShell API 启动脚本。'}
[void](Find-CodexExecutable $Executable)
$temporary=Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N')+'.json')
try{Write-AtomicText $temporary ($config|ConvertTo-Json -Depth 5);[void](Read-ControllerConfig $temporary)}finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
[void][IO.Directory]::CreateDirectory((Split-Path $target -Parent));Write-AtomicText $target ($config|ConvertTo-Json -Depth 5)
Write-Output '已生成控制器配置。没有修改已有配置、读取凭据或启动/停止 Codex。外部启动脚本仅在用户要求启动且实例未运行时执行。'
