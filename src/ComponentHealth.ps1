# Read-only component snapshots. No service construction, process start, pipe connection,
# directory creation, credentials, event database or conversation-file reads.
. "$PSScriptRoot\QuestionBridgeLaunch.ps1"
function Read-ComponentJson([string]$Path,[int]$MaxBytes=1048576) {
    $stream=$null
    try {
        $full=Get-FullDirectory $Path;Assert-NoReparsePoint $full
        if(-not (Test-Path -LiteralPath $full -PathType Leaf -ErrorAction Stop)){return [pscustomobject]@{code='SNAPSHOT_MISSING';data=$null}}
        $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        if($stream.Length -gt $MaxBytes){return [pscustomobject]@{code='SNAPSHOT_OVERSIZE';data=$null}}
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        try{
            # Bound the actual read too: the file may grow after the length check.
            $buffer=New-Object char[] ($MaxBytes+1)
            $count=$reader.ReadBlock($buffer,0,$buffer.Length)
            if($count -gt $MaxBytes){return [pscustomobject]@{code='SNAPSHOT_OVERSIZE';data=$null}}
            $raw=New-Object string($buffer,0,$count)
        }finally{$reader.Dispose();$stream=$null}
        if([string]::IsNullOrWhiteSpace($raw) -or $raw.IndexOf([char]0) -ge 0){return [pscustomobject]@{code='SNAPSHOT_INVALID';data=$null}}
        $value=ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        if($null -eq $value -or $value -isnot [pscustomobject]){return [pscustomobject]@{code='SNAPSHOT_INVALID';data=$null}}
        return [pscustomobject]@{code='READ';data=$value}
    }catch{return [pscustomobject]@{code='SNAPSHOT_UNREADABLE';data=$null}}
    finally{if($stream){$stream.Dispose()}}
}
function New-ComponentHealth([string]$Component,$Configured,[string]$State,[string]$Code,$Stamp=$null) {
    [pscustomobject]@{component=$Component;configured=$Configured;observedState=$State;reasonCode=$Code;lastObservedAt=$Stamp;versionEvidence='not-verified';nextAction='inspect-component'}
}
function Get-AdaptiveBridgeComponentHealth($Config,$Api,[string]$StateDirectory,[string[]]$InstancePaths) {
    # Only a bounded registration and status read. Do not import adaptive runtime or
    # validate candidates here: opening diagnostics must never dispatch work.
    $registration=Read-ComponentJson (Join-Path $StateDirectory 'adaptive-bridge.local.json') 65536
    if($registration.code -eq 'SNAPSHOT_MISSING'){return New-ComponentHealth 'adaptiveBridge' $false 'unconfigured' 'NOT_CONFIGURED'}
    if($registration.code -ne 'READ'){return New-ComponentHealth 'adaptiveBridge' $null 'unknown' $registration.code}
    $entry=$registration.data;$instanceId=[string](Get-DiagnosticValue $Api 'id' '')
    if((Get-DiagnosticValue $entry 'schema' 0) -ne 1 -or $instanceId -notmatch '^[a-f0-9]{32}$' -or (Get-DiagnosticValue $entry 'instanceId' '') -cne $instanceId){return New-ComponentHealth 'adaptiveBridge' $null 'unknown' 'IDENTITY_MISMATCH'}
    $enabled=Get-DiagnosticValue $entry 'enabled' $null
    if($enabled -isnot [bool]){return New-ComponentHealth 'adaptiveBridge' $null 'unknown' 'SETTINGS_UNKNOWN'}
    try {
        $root=Get-FullDirectory ([string](Get-DiagnosticValue $entry 'root' ''));Assert-NoReparsePoint $root
        foreach($prior in @($InstancePaths)+@($StateDirectory)){if(Test-PathOverlap $root $prior){throw 'overlap'}}
        $disabledPath=Join-Path $root 'DISABLED';Assert-NoReparsePoint $disabledPath
        $disabled=Test-Path -LiteralPath $disabledPath -PathType Leaf -ErrorAction Stop
    }catch{return New-ComponentHealth 'adaptiveBridge' $enabled 'unknown' 'PATH_UNSAFE'}
    if(-not $enabled -or $disabled){return New-ComponentHealth 'adaptiveBridge' $false 'disabled' 'ADAPTIVE_DISABLED'}
    $snapshot=Read-ComponentJson (Join-Path $root 'state\status.json') 65536
    if($snapshot.code -ne 'READ'){return New-ComponentHealth 'adaptiveBridge' $true 'unknown' $snapshot.code}
    $value=$snapshot.data;$state=[string](Get-DiagnosticValue $value 'state' '')
    if((Get-DiagnosticValue $value 'schema' 0) -ne 1 -or $state -notin @('normal','waiting_restart','needs_adaptation','disabled','validating')){return New-ComponentHealth 'adaptiveBridge' $true 'unknown' 'SNAPSHOT_INVALID'}
    if((Get-DiagnosticValue $value 'instanceId' '') -cne $instanceId -or
       -not (Test-SamePath ([string](Get-DiagnosticValue $value 'apiHome' '')) ([string](Get-DiagnosticValue $Api 'home' ''))) -or
       -not (Test-SamePath ([string](Get-DiagnosticValue $value 'profile' '')) ([string](Get-DiagnosticValue $Api 'profile' '')))){
        return New-ComponentHealth 'adaptiveBridge' $true 'unknown' 'IDENTITY_MISMATCH'
    }
    $date=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse([string](Get-DiagnosticValue $value 'updatedUtc' ''),[ref]$date)){return New-ComponentHealth 'adaptiveBridge' $true 'unknown' 'TIME_INVALID'}
    $age=([DateTimeOffset]::UtcNow-$date).TotalSeconds;$stamp=$date.ToUniversalTime().ToString('o')
    if($age -lt 0){return New-ComponentHealth 'adaptiveBridge' $true 'unknown' 'TIME_INVALID'}
    # Validation is live work; other states are persisted outcomes, never heartbeats.
    $limit=if($state -eq 'validating'){450}else{604800}
    if($age -gt $limit){return New-ComponentHealth 'adaptiveBridge' $true 'unknown' 'ADAPTIVE_STATUS_STALE' $stamp}
    $map=@{normal=@('validated','ADAPTIVE_BOUND_ONLY');waiting_restart=@('waiting-restart','ADAPTIVE_WAITING_START');needs_adaptation=@('degraded','ADAPTIVE_NEEDS_ADAPTATION');disabled=@('disabled','ADAPTIVE_DISABLED');validating=@('validating','ADAPTIVE_VERIFYING')}
    $mapped=$map[$state]
    $item=New-ComponentHealth 'adaptiveBridge' ($state -ne 'disabled') $mapped[0] $mapped[1] $stamp
    if($state -in @('normal','waiting_restart')){$item.versionEvidence='snapshot-reported-validation'}
    return $item
}
function Get-ComponentHealthText($Item) {
    $names=@{notifications='完成通知';bridge='提问桥接';guard='首字守护后台';guardCli='首字守护 CLI';guardTray='首字守护托盘';adaptiveBridge='升级自适配'}
    $messages=@{
        PATH_CONFLICT='实例目录冲突，停止组件检查。';NOT_CONFIGURED='没有找到该组件的登记。';SETTINGS_UNKNOWN='设置缺失或损坏，无法确认是否启用。'
        SNAPSHOT_MISSING='状态快照不存在，运行状态未确认。';SNAPSHOT_INVALID='状态快照为空、全零或格式无效。';SNAPSHOT_OVERSIZE='状态快照超出读取上限。';SNAPSHOT_UNREADABLE='状态快照无法安全读取。'
        HEARTBEAT_FRESH='后台心跳新鲜；实际功能效果尚未验收。';HEARTBEAT_STALE='后台心跳已过期，需检查组件。';TIME_INVALID='心跳时间无效或位于未来。';WORKER_STOPPED='后台报告已停止。';WORKER_FAILED='后台报告失败。';USER_DISABLED='设置已停用；未验证后台退出。'
        TRAY_UNOBSERVED='快照不提供托盘身份，托盘进程未核验。';CLI_PRESENT='配置的 CLI 文件存在；未验证版本兼容性。';CLI_MISSING='配置的 CLI 已不存在，需核对组件绑定与执行入口。';CLI_UNKNOWN='CLI 路径缺失或无法安全检查。';BACKEND_ERROR='后台快照报告错误，需打开守护查看。'
        PATH_UNSAFE='路径不满足本地普通目录校验。';TRIAL_CONFLICT='生产绑定目录混入试验文件。';BINDING_UNREADABLE='绑定文件缺失、损坏或无法读取。';CONFIG_UNREADABLE='桥接配置缺失、损坏或无法读取。';BINDING_INVALID='桥接绑定格式不匹配。';IDENTITY_MISMATCH='桥接与登记的 API 实例或用户不匹配。';DESKTOP_CHANGED='Desktop 路径已变化，需重新兼容验证。';CONFIG_INVALID='桥接配置与绑定不匹配。';CONFIG_HASH_CHANGED='桥接配置哈希已变化。'
        PROXY_MISSING='桥接程序文件已不存在。';CLI_HASH_CHANGED='CLI 哈希已变化，需重新兼容验证。';PROXY_HASH_CHANGED='桥接程序哈希已变化。';DESKTOP_MISSING='绑定的旧 Desktop 文件已不存在。';DESKTOP_HASH_CHANGED='Desktop 哈希已变化，需重新兼容验证。';ACCESS_DENIED='无法访问组件文件。';VALIDATED_NOT_CONNECTED='文件和实例绑定通过校验；未核验连接及当前运行版本。'
        ADAPTIVE_DISABLED='用户已停用自适配；此处不启动或恢复组件。';ADAPTIVE_VERIFYING='正在验证升级兼容性；尚未接入。';ADAPTIVE_WAITING_START='候选已通过兼容验证，等待下一次启动接入。';ADAPTIVE_BOUND_ONLY='快照报告绑定已验证；没有当前连接证据。';ADAPTIVE_ATTACHED='快照报告当前桥接已接入；实际通知及选项交互仍需验收。';ADAPTIVE_NEEDS_ADAPTATION='兼容验证未通过，需适配；保留原生功能。';ADAPTIVE_STATUS_STALE='自适配状态已陈旧，不能据此确认当前版本或连接。'
    }
    $name=$names[[string](Get-DiagnosticValue $Item 'component' '')];$code=[string](Get-DiagnosticValue $Item 'reasonCode' '')
    if(-not $name -or -not $messages.ContainsKey($code)){return $null}
    $configured=Get-DiagnosticValue $Item 'configured' $null
    $setting=if($configured -is [bool] -and -not $configured){' 配置已停用。'}else{''}
    return ('[组件/{0}/{1}] {2}{3}' -f $name,$code,$messages[$code],$setting)
}
function Get-ControllerComponentHealth($Config) {
    $items=New-Object 'Collections.Generic.List[object]'
    $api=@((Get-DiagnosticValue $Config 'instances' @())|Where-Object {(Get-DiagnosticValue $_ 'role' '') -eq 'api'})
    $official=@((Get-DiagnosticValue $Config 'instances' @())|Where-Object {(Get-DiagnosticValue $_ 'role' '') -eq 'official'})
    try {
        if($api.Count -ne 1 -or $official.Count -ne 1){throw 'ambiguous'}
        $apiHome=Get-FullDirectory ([string](Get-DiagnosticValue $api[0] 'home' ''));Assert-NoReparsePoint $apiHome
        # Reject any configured instance-directory overlap before reading component files.
        $seen=New-Object 'Collections.Generic.List[string]'
        foreach($instance in @($official[0],$api[0])){foreach($key in @('home','profile','projects','projectless')){
            $path=[string](Get-DiagnosticValue $instance $key '');if(-not $path){continue}
            $full=Get-FullDirectory $path;Assert-NoReparsePoint $full
            foreach($prior in $seen){if(Test-PathOverlap $full $prior){throw 'conflict'}}
            $seen.Add($full)
        }}
        $state=Get-FullDirectory ([string](Get-DiagnosticValue $Config 'stateDirectory' ''));Assert-NoReparsePoint $state
        foreach($prior in $seen){if(Test-PathOverlap $state $prior){throw 'conflict'}}
    }catch{
        foreach($component in @('notifications','bridge','guard','guardCli','guardTray','adaptiveBridge')){$items.Add((New-ComponentHealth $component $null 'unknown' 'PATH_CONFLICT'))}
        return $items.ToArray()
    }
    $settings=Read-ComponentJson (Join-Path $state 'notifications\settings.local.json') 65536
    $enabled=Get-DiagnosticValue $settings.data 'enabled' $null
    if($settings.code -ne 'READ' -or $enabled -isnot [bool] -or (Get-DiagnosticValue $settings.data 'schema' 0) -ne 1){$items.Add((New-ComponentHealth 'notifications' $null 'unknown' 'SETTINGS_UNKNOWN'))}
    elseif(-not $enabled){$items.Add((New-ComponentHealth 'notifications' $false 'disabled' 'USER_DISABLED'))}
    else {
        $snapshot=Read-ComponentJson (Join-Path $state 'notifications\worker-status.local.json') 65536
        $code=$snapshot.code;$observed='unknown';$stamp=$null
        if($code -eq 'READ'){
            $code='SNAPSHOT_INVALID';$workerState=Get-DiagnosticValue $snapshot.data 'state' ''
            if((Get-DiagnosticValue $snapshot.data 'schema' 0) -eq 1 -and (Get-DiagnosticValue $snapshot.data 'runId' '') -match '^[a-f0-9]{32}$' -and $workerState -in @('running','stopped','failed')){
                $date=[DateTimeOffset]::MinValue;$code='TIME_INVALID'
                if([DateTimeOffset]::TryParse([string](Get-DiagnosticValue $snapshot.data 'utc' ''),[ref]$date)){
                    $age=([DateTimeOffset]::UtcNow-$date).TotalSeconds
                    if($age -ge 0){$stamp=$date.ToUniversalTime().ToString('o');$code=if($workerState -eq 'failed'){'WORKER_FAILED'}elseif($workerState -eq 'stopped'){'WORKER_STOPPED'}elseif($age -gt 35){'HEARTBEAT_STALE'}else{'HEARTBEAT_FRESH'};$observed=if($code -eq 'HEARTBEAT_FRESH'){'heartbeat-fresh'}else{'degraded'}}
                }
            }
        }
        $items.Add((New-ComponentHealth 'notifications' $true $observed $code $stamp))
    }
    $registration=Read-ComponentJson (Join-Path $state 'question-bridge.local.json') 65536
    if($registration.code -eq 'SNAPSHOT_MISSING'){$items.Add((New-ComponentHealth 'bridge' $false 'unconfigured' 'NOT_CONFIGURED'))}
    elseif($registration.code -ne 'READ'){$items.Add((New-ComponentHealth 'bridge' $null 'unknown' $registration.code))}
    elseif((Get-DiagnosticValue $registration.data 'schema' 0) -ne 1 -or (Get-DiagnosticValue $registration.data 'instanceId' '') -ne (Get-DiagnosticValue $api[0] 'id' '')){$items.Add((New-ComponentHealth 'bridge' $true 'unknown' 'IDENTITY_MISMATCH'))}
    else {
        $validation=Get-ApiQuestionBridgeValidation -Directory ([string](Get-DiagnosticValue $registration.data 'directory' '')) -ApiHome $apiHome -Profile ([string](Get-DiagnosticValue $api[0] 'profile' '')) -InstanceId ([string](Get-DiagnosticValue $api[0] 'id' ''))
        $items.Add((New-ComponentHealth 'bridge' $true $(if($validation.valid){'validated'}else{'unknown'}) $validation.reasonCode))
    }
    $guardRoot=Join-Path $apiHome 'plugin-state\first-token-guard'
    $settings=Read-ComponentJson (Join-Path $guardRoot 'desktop-settings.json') 65536
    $enabled=Get-DiagnosticValue $settings.data 'enabled' $null
    if($settings.code -ne 'READ' -or $enabled -isnot [bool]){
        $items.Add((New-ComponentHealth 'guard' $null 'unknown' 'SETTINGS_UNKNOWN'))
        $items.Add((New-ComponentHealth 'guardCli' $null 'unknown' 'CLI_UNKNOWN'))
    }else {
        $snapshot=Read-ComponentJson (Join-Path $guardRoot 'desktop-status.json')
        $code=$snapshot.code;$observed='unknown';$stamp=$null
        if($code -eq 'READ'){
            $code='SNAPSHOT_INVALID';$last=Get-DiagnosticValue $snapshot.data 'last_check' $null;$backendId=Get-DiagnosticValue $snapshot.data 'pid' $null
            $backendState=Get-DiagnosticValue $snapshot.data 'state' ''
            $hasPid=$null -ne $snapshot.data.PSObject.Properties['pid']
            $stopped=$backendState -eq 'stopped' -and $hasPid -and $null -eq $backendId
            $active=$backendState -in @('standby','monitoring','paused','error') -and ($backendId -is [int] -or $backendId -is [long]) -and $backendId -gt 0
            if(($last -is [int] -or $last -is [long] -or $last -is [double] -or $last -is [decimal]) -and $last -gt 0 -and ($stopped -or $active)){
                try{$date=([DateTimeOffset]'1970-01-01T00:00:00Z').AddSeconds($last);$age=([DateTimeOffset]::UtcNow-$date).TotalSeconds;$code='TIME_INVALID'
                    if($age -ge 0){
                        $stamp=$date.ToString('o')
                        $code=if($stopped){'WORKER_STOPPED'}elseif($age -gt 20){'HEARTBEAT_STALE'}elseif($backendState -eq 'error' -or (Get-DiagnosticValue $snapshot.data 'error' $null)){'BACKEND_ERROR'}else{'HEARTBEAT_FRESH'}
                        $observed=if($stopped){if($enabled){'stopped'}else{'disabled'}}elseif($code -eq 'HEARTBEAT_FRESH'){'heartbeat-fresh'}else{'degraded'}
                    }
                }catch{$code='TIME_INVALID'}
            }
        }
        if(-not $enabled -and $code -eq 'HEARTBEAT_FRESH'){$code='USER_DISABLED';$observed='disabled'}
        $items.Add((New-ComponentHealth 'guard' $enabled $observed $code $stamp))
        $code='CLI_UNKNOWN';$cliState='unknown'
        try{$cli=Get-FullDirectory ([string](Get-DiagnosticValue $settings.data 'cli_executable' ''));Assert-NoReparsePoint $cli
            if(Test-Path -LiteralPath $cli -PathType Leaf -ErrorAction Stop){$code='CLI_PRESENT';$cliState='file-present'}else{$code='CLI_MISSING';$cliState='degraded'}}catch{}
        $items.Add((New-ComponentHealth 'guardCli' $enabled $cliState $code))
    }
    $items.Add((New-ComponentHealth 'guardTray' $null 'unknown' 'TRAY_UNOBSERVED'))
    $items.Add((Get-AdaptiveBridgeComponentHealth $Config $api[0] $state $seen.ToArray()))
    return $items.ToArray()
}
