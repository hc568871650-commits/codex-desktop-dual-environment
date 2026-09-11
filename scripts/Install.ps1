param(
 [string]$InstallDirectory=(Join-Path $env:LOCALAPPDATA 'CodexDualController'),
 [string]$DataDirectory=(Join-Path $env:LOCALAPPDATA 'CodexDualData'),
 [string]$OfficialHome,
 [string]$OfficialProfile='',
 [string]$Executable='',
 [string]$BaseUrl,
 [string]$Model,
 [Security.SecureString]$ApiKey,
 [string]$ShortcutDirectory=[Environment]::GetFolderPath('Desktop'),
 [switch]$NoShortcuts
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
$install=Get-FullDirectory $InstallDirectory;$data=Get-FullDirectory $DataDirectory
Assert-NoReparsePoint $install;Assert-NoReparsePoint $data
$configPath=Join-Path $install 'instances.local.json'
if(Test-Path -LiteralPath $configPath){
    [void](Read-ControllerConfig $configPath)
    if(-not (Test-Path -LiteralPath (Join-Path $install 'src\Controller.ps1'))){throw '此目录只有卸载后保留的配置。请把完整工具解压到新的固定目录，使用 Controller.cmd -ConfigPath 指向这份配置；不会覆盖数据。'}
    Write-Output '已安装：保留已有配置、密钥和快捷方式。升级请使用新的工具目录。';exit
}
if((Test-Path -LiteralPath $install) -and @(Get-ChildItem -LiteralPath $install -Force).Count){throw '安装目录必须为空，不能覆盖已有文件。'}
if(Test-PathOverlap $install $data){throw '工具目录与数据目录必须分开，便于卸载保留数据。'}
if(-not $OfficialHome){$OfficialHome=Read-Host '现有官方 CODEX_HOME 的绝对路径（不会复制认证或历史）'}
$official=Get-FullDirectory $OfficialHome;Assert-NoReparsePoint $official
if(Test-PathOverlap $official $install){throw '工具目录不能与官方数据重叠。'}
if(Test-PathOverlap $official $data){throw '新数据目录不能与已有官方目录重叠。'}
[void](Find-CodexExecutable $Executable)
if(-not $BaseUrl){$BaseUrl=Read-Host 'API Base URL（例如 https://api.openai.com/v1）'}
if(-not $Model){$Model=Read-Host '服务商支持的模型 ID'}
if(-not $ApiKey){$ApiKey=Read-Host 'API Key（本机 DPAPI 加密保存，不回显）' -AsSecureString}
$apiRoot=Join-Path $data 'API'
[void](Assert-EnvironmentRoot $apiRoot $official)
$officialProjects=Join-Path $data 'Official\Projects'
$officialProjectless=Join-Path $data 'Official\Projectless'
$officialConfig=Join-Path $official 'config.toml'
$newOfficialConfig=$false
if(Test-Path -LiteralPath $officialConfig){
    # Only inspect this single non-secret setting; never copy the original file.
    $text=Get-Content -LiteralPath $officialConfig -Raw -Encoding UTF8
    if($text -match '(?ms)^\[desktop\]\s*\r?\n(?<section>.*?)(?=^\[|\z)' -and $Matches.section -match '(?m)^projectlessWorkspaceRoot\s*=\s*''([^'']+)''\s*$'){$officialProjectless=$Matches[1]}
    elseif($text -match '(?ms)^\[desktop\]\s*\r?\n(?<section>.*?)(?=^\[|\z)' -and $Matches.section -match '(?m)^projectlessWorkspaceRoot\s*=\s*"((?:[^"\\]|\\.)+)"\s*$'){$officialProjectless=('"'+$Matches[1]+'"' | ConvertFrom-Json)}
    else{throw '现有官方 config.toml 未找到可安全解析的 desktop.projectlessWorkspaceRoot。请先自行设置该目录；安装器不会修改原配置。'}
    $text=$null
}elseif((Test-Path -LiteralPath $official) -and @(Get-ChildItem -LiteralPath $official -Force).Count){throw '已有官方目录没有 config.toml；请手动配置后重试。'}
else{$newOfficialConfig=$true}
$config=[pscustomobject]@{schema=1;stateDirectory=(Join-Path $install 'state');instances=@(
    [pscustomobject]@{id=[Guid]::NewGuid().ToString('N');role='official';home=$official;profile=$OfficialProfile;projects=$officialProjects;projectless=$officialProjectless;executable=$Executable;launchMode='official'},
    [pscustomobject]@{id=[Guid]::NewGuid().ToString('N');role='api';home=(Join-Path $apiRoot 'CodexHome');profile=(Join-Path $apiRoot 'DesktopProfile');projects=(Join-Path $apiRoot 'Projects');projectless=(Join-Path $apiRoot 'Projectless');executable=$Executable;launchMode='managed-api';apiRoot=$apiRoot}
)}
# Validate full plan before writes, including cross-instance path overlap.
$tempConfig=Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N')+'.json')
try{Write-AtomicText $tempConfig ($config | ConvertTo-Json -Depth 6);[void](Read-ControllerConfig $tempConfig)}finally{if(Test-Path -LiteralPath $tempConfig){[IO.File]::Delete($tempConfig)}}
$source=Split-Path $PSScriptRoot -Parent
[void][IO.Directory]::CreateDirectory($install)
$manifest=[ordered]@{schema=1;root=$install;files=@();shortcuts=@();retainedData=@($official,$data);created= [DateTime]::UtcNow.ToString('o')}
function Save-Manifest {Write-AtomicText (Join-Path $install 'install-manifest.json') ($manifest | ConvertTo-Json -Depth 6)}
Save-Manifest
$installStage='复制工具文件'
try {
    foreach($part in @('.gitignore','version.json','src','scripts','assets','config','docs','README.md','Controller.cmd','Uninstall.cmd','Start.cmd','Install.cmd','Configure.cmd','Upgrade.cmd','Rollback.cmd')){
        $sourcePart=Join-Path $source $part
        if(-not (Test-Path -LiteralPath $sourcePart)){continue}
        $items=if(Test-Path -LiteralPath $sourcePart -PathType Container){@(Get-ChildItem -LiteralPath $sourcePart -File -Recurse)}else{@(Get-Item -LiteralPath $sourcePart)}
        foreach($item in $items){$relative=$item.FullName.Substring($source.Length+1);$target=Join-Path $install $relative
            [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent));[IO.File]::Copy($item.FullName,$target,$false)
            $manifest.files+=@{path=$relative;sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash};Save-Manifest
        }
    }
    $installStage='保存 API 环境'
    [void](Save-ApiEnvironment -Root $apiRoot -OfficialHome $official -BaseUrl $BaseUrl -Model $Model -Key $ApiKey)
    $installStage='写入实例配置'
    foreach($path in @($official,$officialProjects,$officialProjectless,$OfficialProfile)){if($path){[void][IO.Directory]::CreateDirectory($path)}}
    if($newOfficialConfig){Write-AtomicText $officialConfig ("[desktop]`r`nprojectlessWorkspaceRoot = "+(ConvertTo-TomlString $officialProjectless)+"`r`n")}
    Write-AtomicText $configPath ($config | ConvertTo-Json -Depth 6)
    $hostPath=Join-Path $install 'CodexDualController.exe'
    $installStage='编译控制器 EXE'
    & "$PSScriptRoot\Build-ControllerHost.ps1" -Destination $hostPath | Out-Null
    $manifest.files+=@{path='CodexDualController.exe';sha256=(Get-FileHash -LiteralPath $hostPath).Hash};Save-Manifest
    # Local configuration is retained on uninstall as a recovery aid; it contains no credentials.
    if(-not $NoShortcuts){
        $installStage='创建快捷方式'
        [void][IO.Directory]::CreateDirectory($ShortcutDirectory);$shell=New-Object -ComObject WScript.Shell
        foreach($pair in @(@('Codex 官方','official','official.ico'),@('Codex API','api','api.ico'),@('Codex 双环境控制器','tray','controller.ico'))){
            $linkPath=Join-Path $ShortcutDirectory ($pair[0]+'.lnk')
            if(Test-Path -LiteralPath $linkPath){throw '同名快捷方式已存在，保留原文件；请选择空快捷方式目录。'}
            $link=$shell.CreateShortcut($linkPath);$link.TargetPath="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $link.Arguments='-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $install 'src\Controller.ps1')+'" -ConfigPath "'+$configPath+'" -Action '+$pair[1]
            if($pair[1] -eq 'tray'){$link.TargetPath=$hostPath;$link.Arguments=''}
            $link.WorkingDirectory=$install;$link.IconLocation=(Join-Path $install ('assets\'+$pair[2]));$link.Save()
            $manifest.shortcuts+=@{path=$linkPath;sha256=(Get-FileHash -LiteralPath $linkPath).Hash};Save-Manifest
        }
    }
    Write-Output "安装完成：$install。用户数据：$data。未启动或停止任何 Codex 实例。"
}catch{
    $installError=$_
    # A recovery-write failure must not replace the original installation error.
    try{Save-Manifest}catch{Write-Warning '安装记录补写失败；已有清单可能不完整。'}
    Write-Warning ("安装未完成，失败阶段：$installStage。可运行安装目录 scripts\Uninstall.ps1 按已有清单回滚工具；数据保留。")
    throw $installError
}
finally{if($ApiKey){$ApiKey.Dispose()}}
