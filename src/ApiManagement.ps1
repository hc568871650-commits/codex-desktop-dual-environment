Set-StrictMode -Version Latest

function Assert-ManagedApi($Config,$Instance) {
    if($Instance.role -ne 'api' -or $Instance.launchMode -ne 'managed-api'){throw '此环境沿用外部启动器。请通过原管理工具修改 API；内置管理仅支持本工具创建的 API 环境。'}
    $official=@($Config.instances|Where-Object {$_.role -eq 'official'})[0]
    [void](Assert-EnvironmentRoot $Instance.apiRoot $official.home)
}
function Assert-ApiStopped($Config,$Instance) {
    $status=Get-InstanceStatus $Config $Instance
    if($status.State -ne 'Stopped'){throw '请先结束任务并退出此 API 实例，再切换配置管理方式或恢复备份。'}
}
function Read-ApiProfiles($Config,$Instance) {
    Assert-ManagedApi $Config $Instance
    $path=Join-Path $Instance.apiRoot 'api-providers.local.json';Assert-NoReparsePoint $path
    if(Test-Path -LiteralPath $path){
        $data=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if($data.schema -ne 1){throw '不支持的 API 渠道列表版本。'}
        if(-not $data.PSObject.Properties['pendingProfile']){$data|Add-Member NoteProperty pendingProfile $null}
        $ids=@()
        foreach($profile in $data.profiles){if($profile.id -notmatch '^[a-z0-9-]{1,40}$' -or $profile.id -in $ids){throw '渠道 ID 无效或重复。'};$ids+=$profile.id}
        return $data
    }
    if((Get-ApiManagementMode $Instance.apiRoot) -ne 'builtin'){return [pscustomobject]@{schema=1;activeId='';pendingProfile=$null;profiles=@()}}
    $meta=Get-Content -LiteralPath (Join-Path $Instance.apiRoot '.codex-dual.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $keyPath=Join-Path $Instance.apiRoot 'Credentials\api-key.dpapi';Assert-NoReparsePoint $keyPath
    $encrypted=Get-Content -LiteralPath $keyPath -Raw -Encoding UTF8
    return [pscustomobject]@{schema=1;activeId='legacy';pendingProfile=$null;profiles=@([pscustomobject]@{id='legacy';name='原有 API';baseUrl=$meta.baseUrl;model=$meta.model;keyDpapi=$encrypted.Trim()})}
}
function Save-ApiProfile($Config,$Instance,[string]$Id,[string]$Name,[string]$BaseUrl,[string]$Model,[Security.SecureString]$Key) {
    Invoke-InstanceLocked $Instance {
        Assert-ManagedApi $Config $Instance
        if((Get-ApiManagementMode $Instance.apiRoot) -ne 'builtin'){throw '请在 CCS 中管理渠道。'}
        if([string]::IsNullOrWhiteSpace($Name) -or $Name.Trim().Length -gt 40 -or $Name -match '[\x00-\x1f]'){throw '渠道名称应为 1–40 个字符。'}
        [void](New-ApiConfig $Instance.apiRoot $BaseUrl $Model)
        $data=Read-ApiProfiles $Config $Instance
        $existing=@($data.profiles|Where-Object {$_.id -eq $Id})
        if($Id -and $existing.Count -ne 1){throw '渠道已变化，请刷新列表。'}
        if(-not $Id){$Id=[Guid]::NewGuid().ToString('N')}
        if(@($data.profiles|Where-Object {$_.id -ne $Id -and $_.name -eq $Name.Trim()}).Count){throw '已有同名渠道，请使用其他名称。'}
        if($Key -and $Key.Length){$encrypted=ConvertFrom-SecureString $Key}
        elseif($existing.Count){$encrypted=$existing[0].keyDpapi}else{throw '新增渠道需要 API Key。'}
        $profile=[pscustomobject]@{id=$Id;name=$Name.Trim();baseUrl=$BaseUrl.Trim().TrimEnd('/');model=$Model.Trim();keyDpapi=$encrypted}
        $data.profiles=@($data.profiles|Where-Object {$_.id -ne $Id})+@($profile)
        Write-AtomicText (Join-Path $Instance.apiRoot 'api-providers.local.json') ($data|ConvertTo-Json -Depth 8)
        return $Id
    }
}
function Remove-ApiProfile($Config,$Instance,[string]$Id) {
    Invoke-InstanceLocked $Instance {
        if((Get-ApiManagementMode $Instance.apiRoot) -ne 'builtin'){throw '请在 CCS 中管理渠道。'}
        $data=Read-ApiProfiles $Config $Instance
        if($data.activeId -eq $Id){throw '请先应用另一个渠道，再删除当前渠道。'}
        if($data.pendingProfile -and $data.pendingProfile.id -eq $Id){throw '此渠道等待下次启动时应用，请先改选其他渠道。'}
        $data.profiles=@($data.profiles|Where-Object {$_.id -ne $Id})
        Write-AtomicText (Join-Path $Instance.apiRoot 'api-providers.local.json') ($data|ConvertTo-Json -Depth 8)
    }
}
function New-ApiBackup($Config,$Instance,[string]$Reason) {
    Assert-ManagedApi $Config $Instance
    $files=@{}
    foreach($relative in @('CodexHome\config.toml','CodexHome\auth.json','Credentials\api-key.dpapi','.codex-dual.json','api-providers.local.json')){
        $path=Join-Path $Instance.apiRoot $relative;Assert-NoReparsePoint $path
        $files[$relative]=if(Test-Path -LiteralPath $path){[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))}else{$null}
    }
    $secure=ConvertTo-SecureString ($files|ConvertTo-Json -Depth 5 -Compress) -AsPlainText -Force
    try{$payload=ConvertFrom-SecureString $secure}finally{$secure.Dispose()}
    $folder=Join-Path $Instance.apiRoot 'Backup';Assert-NoReparsePoint $folder;[void][IO.Directory]::CreateDirectory($folder)
    $path=Join-Path $folder ('snapshot-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N')+'.local.json')
    Write-AtomicText $path (@{schema=1;instanceId=$Instance.id;root=$Instance.apiRoot;created=[DateTime]::Now.ToString('o');reason=$Reason;protectedFiles=$payload}|ConvertTo-Json)
    return $path
}
function Read-ApiBackup($Config,$Instance,[string]$Path) {
    Assert-ManagedApi $Config $Instance
    $path=Get-FullDirectory $Path;Assert-NoReparsePoint $path
    $folder=Get-FullDirectory (Join-Path $Instance.apiRoot 'Backup')
    if(-not (Test-SamePath (Split-Path $path -Parent) $folder)){throw '请选择此 API 环境内的配置快照。'}
    $snapshot=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    if($snapshot.schema -ne 1 -or $snapshot.instanceId -ne $Instance.id -or -not (Test-SamePath $snapshot.root $Instance.apiRoot)){throw '备份不属于此实例。'}
    $secure=$snapshot.protectedFiles|ConvertTo-SecureString;$pointer=[IntPtr]::Zero
    try{$pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure);$files=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)|ConvertFrom-Json}
    finally{if($pointer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)};$secure.Dispose()}
    $changes=@{}
    foreach($property in $files.PSObject.Properties){$changes[$property.Name]=if($null -eq $property.Value){$null}else{[Convert]::FromBase64String($property.Value)}}
    return $changes
}
function Restore-ApiBackup($Config,$Instance,[string]$Path) {
    Invoke-InstanceLocked $Instance {
        Assert-ApiStopped $Config $Instance
        if((Get-ApiManagementMode $Instance.apiRoot) -ne 'builtin'){throw 'CCS 管理期间请使用“恢复内置管理”，避免两个工具同时修改配置。'}
        $changes=Read-ApiBackup $Config $Instance $Path
        [void](New-ApiBackup $Config $Instance '恢复前自动备份')
        Write-ApiTransaction $Instance.apiRoot $changes
    }
}
function Apply-ApiProfile($Config,$Instance,[string]$Id,[switch]$UsePending) {
    Invoke-InstanceLocked $Instance {
        Assert-ManagedApi $Config $Instance
        if((Get-ApiManagementMode $Instance.apiRoot) -ne 'builtin'){throw '请在 CCS 中切换渠道。'}
        $data=Read-ApiProfiles $Config $Instance;$profiles=@($data.profiles|Where-Object {$_.id -eq $Id})
        if($profiles.Count -ne 1){throw '所选渠道不存在。'}
        $profile=$profiles[0]
        if($UsePending){if(-not $data.pendingProfile -or $data.pendingProfile.id -ne $Id){throw '待应用渠道已变化。'};$profile=$data.pendingProfile}
        $status=Get-InstanceStatus $Config $Instance
        if($status.State -eq 'Running'){
            $data.pendingProfile=$profile
            Write-AtomicText (Join-Path $Instance.apiRoot 'api-providers.local.json') ($data|ConvertTo-Json -Depth 8)
            return 'Deferred'
        }
        if($status.State -ne 'Stopped'){throw '无法确认 API 实例已停止，渠道未应用。'}
        $official=@($Config.instances|Where-Object {$_.role -eq 'official'})[0]
        $key=$profile.keyDpapi|ConvertTo-SecureString
        try{
            [void](Merge-ApiConfig ([IO.File]::ReadAllText((Join-Path $Instance.home 'config.toml'))) $Instance.apiRoot $profile.baseUrl $profile.model)
            $snapshot=New-ApiBackup $Config $Instance '应用渠道前'
            try{
                [void](Save-ApiEnvironment $Instance.apiRoot $official.home $profile.baseUrl $profile.model $key)
                $data.activeId=$Id
                $data.pendingProfile=$null
                Write-AtomicText (Join-Path $Instance.apiRoot 'api-providers.local.json') ($data|ConvertTo-Json -Depth 8)
            }catch{$failure=$_;try{Write-ApiTransaction $Instance.apiRoot (Read-ApiBackup $Config $Instance $snapshot)}catch{Write-Warning '应用失败，自动回退未完成，请使用快照恢复。'};throw $failure}
        }finally{$key.Dispose()}
        return 'Applied'
    }
}
function Get-CcsSettingsPath {
    $root=Join-Path $env:USERPROFILE '.cc-switch'
    $overrideFile=Join-Path $env:APPDATA 'com.ccswitch.desktop\app_paths.json'
    if(Test-Path -LiteralPath $overrideFile){
        $override=Get-Content -LiteralPath $overrideFile -Raw -Encoding UTF8|ConvertFrom-Json
        $custom=Get-ObjectValue $override 'app_config_dir_override' ''
        if($custom -and (Test-Path -LiteralPath $custom -PathType Container)){$root=Get-FullDirectory $custom}
    }
    return Join-Path $root 'settings.json'
}
function Test-CcsBinding($Instance,[string]$SettingsPath,[string]$Executable) {
    $settings=Get-FullDirectory $SettingsPath;$exe=Get-FullDirectory $Executable
    Assert-NoReparsePoint $settings;Assert-NoReparsePoint $exe
    if(-not (Test-Path -LiteralPath $exe -PathType Leaf) -or [IO.Path]::GetExtension($exe) -ne '.exe'){throw '请选择已安装的 CC Switch EXE。'}
    if(-not (Test-Path -LiteralPath $settings -PathType Leaf)){throw '未找到 CCS settings.json，请先在 CCS 中设置 Codex 配置目录。'}
    $state=Get-Content -LiteralPath $settings -Raw -Encoding UTF8|ConvertFrom-Json
    $codexDir=Get-ObjectValue $state 'codexConfigDir' ''
    if(-not $codexDir -or -not (Test-SamePath $codexDir $Instance.home)){throw ('CCS 的 Codex 配置目录与 API 环境不一致。请在 CCS 中设置为：'+$Instance.home)}
    return $true
}
function Enable-CcsManagement($Config,$Instance,[string]$SettingsPath,[string]$Executable) {
    Invoke-InstanceLocked $Instance {
        Assert-ManagedApi $Config $Instance;Assert-ApiStopped $Config $Instance
        [void](Test-CcsBinding $Instance $SettingsPath $Executable)
        if(-not (Test-SamePath $SettingsPath (Get-CcsSettingsPath))){throw '请选择当前 CCS 实际使用的设置目录，不能把实验设置绑定到正常 CCS 入口。'}
        if((Get-ApiManagementMode $Instance.apiRoot) -ne 'builtin'){throw '此环境已交给 CCS 管理。'}
        $official=@($Config.instances|Where-Object {$_.role -eq 'official'})[0]
        $probe=New-CodexStartInfo -Executable $Executable -OfficialHome $official.home -ApiRoot $Instance.apiRoot -Api
        $probe.EnvironmentVariables.Remove('CODEX_DUAL_API_KEY')
        $snapshot=New-ApiBackup $Config $Instance '交给 CCS 前的内置配置'
        $path=Join-Path $Instance.apiRoot '.codex-dual.json';$meta=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        foreach($pair in @(@('managementMode','ccs'),@('builtinSnapshot',$snapshot),@('ccsSettingsPath',$SettingsPath),@('ccsExecutable',$Executable))){$meta|Add-Member NoteProperty $pair[0] $pair[1] -Force}
        Write-AtomicText $path ($meta|ConvertTo-Json -Depth 6)
    }
}
function Disable-CcsManagement($Config,$Instance) {
    Invoke-InstanceLocked $Instance {
        Assert-ManagedApi $Config $Instance;Assert-ApiStopped $Config $Instance
        $path=Join-Path $Instance.apiRoot '.codex-dual.json';$meta=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if((Get-ObjectValue $meta 'managementMode' 'builtin') -ne 'ccs'){throw '当前已是内置管理。'}
        if(@(Get-ProcessSnapshot|Where-Object {Test-SamePath $_.Path $meta.ccsExecutable}).Count){throw '请先退出 CCS，再恢复内置管理，避免 CCS 再次覆盖配置。'}
        $changes=Read-ApiBackup $Config $Instance $meta.builtinSnapshot
        [void](New-ApiBackup $Config $Instance '恢复内置管理前的 CCS 配置')
        Write-ApiTransaction $Instance.apiRoot $changes
    }
}
function Open-CcsManager($Instance,[string]$SettingsPath,[string]$Executable,[switch]$Configure) {
    if(-not (Test-SamePath $SettingsPath (Get-CcsSettingsPath))){throw 'CCS 实际设置目录已变化，请重新检查接入。'}
    if($Configure){
        $Executable=Get-FullDirectory $Executable;Assert-NoReparsePoint $Executable
        if(-not (Test-Path -LiteralPath $Executable -PathType Leaf) -or [IO.Path]::GetExtension($Executable) -ne '.exe'){throw '请选择已安装的 CC Switch EXE。'}
    }else{[void](Test-CcsBinding $Instance $SettingsPath $Executable)}
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$Executable;$psi.UseShellExecute=$false;$psi.WorkingDirectory=Split-Path $Executable -Parent
    foreach($name in @($psi.EnvironmentVariables.Keys)){if($name -match '^(CODEX_|OPENAI_|CHATGPT_|ELECTRON_|CC_SWITCH_)' -or $name -in @('HOME','NODE_OPTIONS','CUSTOM_API_KEY','WEBVIEW2_USER_DATA_FOLDER')){$psi.EnvironmentVariables.Remove($name)}}
    [void][CodexDual.Native]::StartDetached($psi)
}
