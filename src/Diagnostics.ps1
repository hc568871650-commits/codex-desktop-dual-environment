Set-StrictMode -Version Latest

function Get-DiagnosticValue($Object, [string]$Name, $Default = $null) {
    if($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)){return $Object[$Name]}
    if($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name}
    return $Default
}

function Add-DiagnosticCheck($Checks, [string]$Role, [string]$Code, [string]$Severity) {
    $catalog=@{
        CONFIG_INVALID=@('配置不完整或角色冲突。','检查实例配置，确保官方和 API 角色各有一个。')
        PATH_CONFLICT=@('实例数据目录存在重叠。','检查配置中的实例目录，确保彼此独立。')
        DIRECTORY_MISSING=@('必要目录不存在。','完成对应实例部署并检查目录配置。')
        DIRECTORY_UNKNOWN=@('目录无法安全检查。','检查目录配置和访问权限。')
        PROFILE_NATIVE=@('官方实例使用原生默认桌面数据目录。','无需单独配置 Desktop profile。')
        PROJECTLESS_UNKNOWN=@('无法确认官方继承的任务目录。','检查官方配置中的 desktop.projectlessWorkspaceRoot。')
        STATUS_RUNNING=@('实例正在运行；不代表任务空闲。','操作实例前先确认其中任务状态。')
        STATUS_STOPPED=@('实例未运行。','需要时从控制面板启动实例。')
        STATUS_UNKNOWN=@('无法可靠判定实例运行状态。','检查程序入口和进程归属后重试。')
        MODE_BUILTIN=@('API 配置由控制器内置管理。','在控制面板中管理渠道。')
        MODE_CCS=@('API 配置由 CCS 管理。','在 CCS 中检查渠道配置。')
        MODE_EXTERNAL=@('API 配置由外部启动器管理。','在原管理工具中检查配置。')
        MODE_UNKNOWN=@('无法可靠判定 API 管理方式。','检查 API 配置元数据。')
        CCS_BINDING_OK=@('CCS 配置目录与 API 环境匹配。','在 CCS 中管理渠道。')
        CCS_BINDING_INVALID=@('CCS 绑定与 API 环境不匹配或无法安全检查。','检查 CCS 设置路径、程序入口及 Codex 配置目录。')
        LAUNCHER_PRESENT=@('外部启动器入口存在。','在原管理工具中检查渠道。')
        LAUNCHER_MISSING=@('外部启动器入口不存在。','检查启动器配置及文件是否仍存在。')
        LAUNCHER_UNKNOWN=@('外部启动器入口无法安全检查。','检查启动器路径与访问权限。')
        CREDENTIAL_PRESENT=@('内置凭据入口存在；未读取凭据。','如启动失败，请在控制面板检查渠道。')
        CREDENTIAL_MISSING=@('内置凭据入口不存在。','在控制面板中重新配置 API 凭据。')
        CREDENTIAL_UNKNOWN=@('无法安全检查凭据入口。','检查 API 环境目录和访问权限。')
        VERSION_UNKNOWN=@('无法确认控制器版本。','检查安装包的版本文件。')
    }
    $entry=$catalog[$Code]
    if($null -eq $entry -or $Severity -notin @('ok','warning','error') -or $Role -notin @('controller','official','api')){throw '诊断检查项无效。'}
    [void]$Checks.Add([pscustomobject]@{Role=$Role;Code=$Code;Severity=$Severity;Message=$entry[0];Advice=$entry[1]})
}

function Get-ControllerDiagnostics($Config, [string]$ToolRoot) {
    $checks=New-Object 'Collections.Generic.List[object]'
    $instances=New-Object 'Collections.Generic.List[object]'
    $version='unknown'
    try {
        $safeToolRoot=Get-FullDirectory $ToolRoot
        Assert-NoReparsePoint $safeToolRoot
        $versionFile=Join-Path $safeToolRoot 'version.json'
        Assert-NoReparsePoint $versionFile
        $data=Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $candidate=[string](Get-DiagnosticValue $data 'version' '')
        if((Get-DiagnosticValue $data 'product' '') -eq 'codex-desktop-dual-environment' -and $candidate -match '^\d{1,4}(\.\d{1,4}){1,3}$'){$version=$candidate}
    }catch{}
    if($version -eq 'unknown'){Add-DiagnosticCheck $checks 'controller' 'VERSION_UNKNOWN' 'warning'}

    $os=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Windows'}else{'Other'}
    $psVersion='{0}.{1}' -f $PSVersionTable.PSVersion.Major,$PSVersionTable.PSVersion.Minor
    $configured=@(Get-DiagnosticValue $Config 'instances' @())
    $roles=@($configured | ForEach-Object {Get-DiagnosticValue $_ 'role' ''})
    if((Get-DiagnosticValue $Config 'schema' 0) -ne 1 -or $configured.Count -ne 2 -or
        @($roles | Where-Object {$_ -eq 'official'}).Count -ne 1 -or
        @($roles | Where-Object {$_ -eq 'api'}).Count -ne 1) {
        Add-DiagnosticCheck $checks 'controller' 'CONFIG_INVALID' 'error'
    }

    $paths=New-Object 'Collections.Generic.List[string]'
    foreach($role in @('official','api')) {
        $matches=@($configured | Where-Object {(Get-DiagnosticValue $_ 'role' '') -eq $role})
        if($matches.Count -ne 1){continue}
        $instance=$matches[0]
        $directories=[ordered]@{}
        $missing=$false;$unreadable=$false;$overlap=$false
        foreach($key in @('home','profile','projects','projectless')) {
            $path=[string](Get-DiagnosticValue $instance $key '')
            if($key -eq 'profile' -and $role -eq 'official' -and -not $path){
                $directories[$key]=$null
                Add-DiagnosticCheck $checks $role 'PROFILE_NATIVE' 'ok'
                continue
            }
            if($key -eq 'projectless' -and $role -eq 'official' -and (Get-DiagnosticValue $instance 'projectlessMode' '') -eq 'inherit'){
                try {
                    $officialHomePath=Get-FullDirectory ([string](Get-DiagnosticValue $instance 'home' ''))
                    Assert-NoReparsePoint $officialHomePath
                    $path=Get-ConfiguredProjectless $officialHomePath
                    if(-not $path){throw 'unresolved'}
                }catch{$directories[$key]=$null;$unreadable=$true;Add-DiagnosticCheck $checks $role 'PROJECTLESS_UNKNOWN' 'warning';continue}
            }
            if([string]::IsNullOrWhiteSpace($path)){$directories[$key]=$false;$missing=$true;continue}
            try {
                $full=Get-FullDirectory $path
                Assert-NoReparsePoint $full
                foreach($previous in $paths){if(Test-PathOverlap $full $previous){$overlap=$true}}
                $paths.Add($full)
                $directories[$key]=[bool](Test-Path -LiteralPath $full -PathType Container -ErrorAction Stop)
                if(-not $directories[$key]){$missing=$true}
            }catch{$directories[$key]=$false;$unreadable=$true}
        }
        if($overlap){Add-DiagnosticCheck $checks $role 'PATH_CONFLICT' 'error'}
        if($missing){Add-DiagnosticCheck $checks $role 'DIRECTORY_MISSING' 'error'}
        if($unreadable){Add-DiagnosticCheck $checks $role 'DIRECTORY_UNKNOWN' 'warning'}

        $state='Unknown'
        try {
            $observed=[string](Get-DiagnosticValue (Get-InstanceStatus $Config $instance) 'State' '')
            if($observed -in @('Running','Stopped')){$state=$observed}
        }catch{}
        $stateCode=if($state -eq 'Running'){'STATUS_RUNNING'}elseif($state -eq 'Stopped'){'STATUS_STOPPED'}else{'STATUS_UNKNOWN'}
        Add-DiagnosticCheck $checks $role $stateCode $(if($state -eq 'Unknown'){'warning'}else{'ok'})

        $mode='not-applicable';$credential=$null
        if($role -eq 'api') {
            if((Get-DiagnosticValue $instance 'launchMode' '') -eq 'managed-api') {
                $mode='unknown'
                try {
                    $root=Get-FullDirectory ([string](Get-DiagnosticValue $instance 'apiRoot' ''))
                    Assert-NoReparsePoint $root
                    $observed=[string](Get-ApiManagementMode $root)
                    if($observed -in @('builtin','ccs')){$mode=$observed}
                }catch{}
                $modeCode=if($mode -eq 'builtin'){'MODE_BUILTIN'}elseif($mode -eq 'ccs'){'MODE_CCS'}else{'MODE_UNKNOWN'}
                Add-DiagnosticCheck $checks $role $modeCode $(if($mode -eq 'unknown'){'warning'}else{'ok'})
                if($mode -eq 'builtin') {
                    try {
                        $entry=Join-Path $root 'Credentials\api-key.dpapi'
                        Assert-NoReparsePoint $entry
                        $credential=[bool](Test-Path -LiteralPath $entry -PathType Leaf -ErrorAction Stop)
                        Add-DiagnosticCheck $checks $role $(if($credential){'CREDENTIAL_PRESENT'}else{'CREDENTIAL_MISSING'}) $(if($credential){'ok'}else{'error'})
                    }catch{Add-DiagnosticCheck $checks $role 'CREDENTIAL_UNKNOWN' 'warning'}
                }
                if($mode -eq 'ccs'){
                    try {
                        $metadataPath=Join-Path $root '.codex-dual.json'
                        Assert-NoReparsePoint $metadataPath
                        $meta=Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
                        [void](Test-CcsBinding $instance $meta.ccsSettingsPath $meta.ccsExecutable)
                        Add-DiagnosticCheck $checks $role 'CCS_BINDING_OK' 'ok'
                    }catch{Add-DiagnosticCheck $checks $role 'CCS_BINDING_INVALID' 'error'}
                }
            }elseif((Get-DiagnosticValue $instance 'launchMode' '') -eq 'external'){
                $mode='external';Add-DiagnosticCheck $checks $role 'MODE_EXTERNAL' 'ok'
                try {
                    $launcher=Get-FullDirectory ([string](Get-DiagnosticValue $instance 'externalLauncher' ''))
                    Assert-NoReparsePoint $launcher
                    $present=[bool](Test-Path -LiteralPath $launcher -PathType Leaf -ErrorAction Stop)
                    Add-DiagnosticCheck $checks $role $(if($present){'LAUNCHER_PRESENT'}else{'LAUNCHER_MISSING'}) $(if($present){'ok'}else{'error'})
                }catch{Add-DiagnosticCheck $checks $role 'LAUNCHER_UNKNOWN' 'warning'}
            }else{$mode='unknown';Add-DiagnosticCheck $checks $role 'MODE_UNKNOWN' 'warning'}
        }
        $instances.Add([pscustomobject]@{Role=$role;State=$state;Directories=[pscustomobject]$directories;ManagementMode=$mode;CredentialEntryPresent=$credential})
    }
    return [pscustomobject]@{Schema=1;Version=$version;Runtime=[pscustomobject]@{OS=$os;PowerShell=$psVersion};Instances=@($instances.ToArray());Checks=@($checks.ToArray())}
}

function ConvertTo-ControllerDiagnosticText($Report) {
    $lines=New-Object 'Collections.Generic.List[string]'
    [void]$lines.Add('Codex 双环境 - 可分享诊断报告')
    [void]$lines.Add('版本：'+$(if(([string]$Report.Version) -match '^\d{1,4}(\.\d{1,4}){1,3}$'){$Report.Version}else{'unknown'}))
    [void]$lines.Add('系统：'+$(if($Report.Runtime.OS -eq 'Windows'){'Windows'}else{'Other'}))
    [void]$lines.Add('PowerShell：'+$(if(([string]$Report.Runtime.PowerShell) -match '^\d{1,3}\.\d{1,3}$'){$Report.Runtime.PowerShell}else{'unknown'}))
    foreach($instance in @($Report.Instances)) {
        if($instance.Role -notin @('official','api')){continue}
        $role=if($instance.Role -eq 'official'){'官方'}else{'API'}
        $state=switch($instance.State){'Running'{'运行中（不代表任务空闲）'} 'Stopped'{'未启动'} default{'未确认'}}
        [void]$lines.Add("[$role] 状态：$state")
        foreach($key in @('home','profile','projects','projectless')) {
            $value=Get-DiagnosticValue $instance.Directories $key $null
            $label=@{home='配置目录';profile='桌面数据目录';projects='项目目录';projectless='无项目任务目录'}[$key]
            if($null -ne $value){[void]$lines.Add(('  {0}：{1}' -f $label,$(if([bool]$value){'存在'}else{'缺少或无法检查'})))}
        }
        if($instance.Role -eq 'api') {
            $mode=switch($instance.ManagementMode){'builtin'{'控制器内置'} 'ccs'{'CC Switch'} 'external'{'外部启动器'} default{'未确认'}}
            [void]$lines.Add('  管理方式：'+$mode)
            if($null -ne $instance.CredentialEntryPresent){[void]$lines.Add('  凭据入口：'+$(if([bool]$instance.CredentialEntryPresent){'存在（未验证有效性）'}else{'缺少'}))}
        }
    }
    foreach($check in @($Report.Checks)) {
        $safe=New-Object 'Collections.Generic.List[object]'
        $role=[string](Get-DiagnosticValue $check 'Role' '')
        $code=[string](Get-DiagnosticValue $check 'Code' '')
        $severity=[string](Get-DiagnosticValue $check 'Severity' '')
        try{Add-DiagnosticCheck $safe $role $code $severity}catch{continue}
        $item=$safe[0]
        $roleLabel=@{controller='控制器';official='官方';api='API'}[$item.Role]
        $severityLabel=@{ok='正常';warning='待确认';error='需处理'}[$item.Severity]
        [void]$lines.Add(('[{0}/{1}/{2}] {3} 建议：{4}' -f $roleLabel,$severityLabel,$item.Code,$item.Message,$item.Advice))
    }
    [void]$lines.Add('仅执行本机只读检查；未发送 API 请求或读取凭据内容。运行状态不代表任务空闲。')
    return ($lines -join [Environment]::NewLine)
}

function Export-ControllerDiagnostics($Report, [string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path)){throw '请选择诊断报告保存位置。'}
    $text=ConvertTo-ControllerDiagnosticText $Report
    $stream=$null
    try {
        $stream=New-Object IO.FileStream($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($text)
        $stream.Write($bytes,0,$bytes.Length)
    }finally{if($stream){$stream.Dispose()}}
}
