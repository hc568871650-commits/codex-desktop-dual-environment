Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Core.ps1"
if($env:PROCESSOR_ARCHITECTURE -ne 'AMD64'){throw '实例控制目前要求 x64 Windows PowerShell。其他架构不进行进程操作。'}
if (-not ('CodexDual.Native' -as [type])) { Add-Type -Path "$PSScriptRoot\Native.cs" }

function Get-ObjectValue($Object, [string]$Name, $Default = $null) {
    if($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)){return $Object[$Name]}
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }; return $Default
}
. "$PSScriptRoot\Preferences.ps1"
. "$PSScriptRoot\ApiManagement.ps1"
function Test-SamePath([string]$A,[string]$B) {
    if (-not $A -or -not $B) { return $false }
    try { return (Get-FullDirectory $A).Equals((Get-FullDirectory $B),[StringComparison]::OrdinalIgnoreCase) } catch { return $false }
}
function Get-ProfileArgument([string]$CommandLine) {
    $argsList = [CodexDual.Native]::Arguments($CommandLine)
    $found = @()
    for($i=1;$i -lt $argsList.Count;$i++) {
        if ($argsList[$i] -eq '--user-data-dir') { $i++; if($i -ge $argsList.Count){throw '缺少 profile 参数值。'}; $found += $argsList[$i] }
        elseif($argsList[$i].StartsWith('--user-data-dir=')) { $found += $argsList[$i].Substring(16) }
    }
    if($found.Count -gt 1){throw '重复 profile 参数，归属不明。'}
    if($found.Count -eq 1){return Get-FullDirectory $found[0]};return ''
}
function Read-ControllerConfig([string]$Path) {
    Assert-NoReparsePoint $Path
    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if($config.schema -ne 1 -or @($config.instances).Count -ne 2){throw '配置必须包含两个实例，schema=1。'}
    $ids=@();$roles=@();$paths=@()
    foreach($instance in $config.instances) {
        if($instance.id -notmatch '^[a-f0-9]{32}$' -or $instance.id -in $ids){throw '实例 ID 无效或重复。'}
        if($instance.role -notin @('official','api') -or $instance.role -in $roles){throw '实例角色无效或重复。'}
        $ids+=$instance.id;$roles+=$instance.role
        if($instance.launchMode -notin @('official','managed-api','external')){throw '未知启动方式。'}
        foreach($key in @('home','projects','projectless')) {
            if($key -eq 'projectless' -and $instance.role -eq 'official' -and -not $instance.projectless -and (Get-ObjectValue $instance 'projectlessMode' '') -eq 'inherit'){continue}
            $full=Get-FullDirectory $instance.$key; Assert-NoReparsePoint $full; $instance.$key=$full
            foreach($prior in $paths){if(Test-PathOverlap $full $prior){throw '实例数据目录不能相同或嵌套。'}};$paths+=$full
        }
        if($instance.profile) {
            $instance.profile=Get-FullDirectory $instance.profile;Assert-NoReparsePoint $instance.profile
            foreach($prior in $paths){if(Test-PathOverlap $instance.profile $prior){throw 'Desktop profile 与数据目录重叠。'}};$paths+=$instance.profile
        } elseif($instance.role -ne 'official'){throw 'API 实例必须设置 Desktop profile。'}
        if($instance.launchMode -eq 'external' -and -not (Get-ObjectValue $instance 'externalLauncher')){throw '外部启动方式缺少脚本路径。'}
        if($instance.launchMode -eq 'managed-api') {
            $apiRoot=Get-FullDirectory $instance.apiRoot
            foreach($pair in @(@('home','CodexHome'),@('profile','DesktopProfile'),@('projects','Projects'),@('projectless','Projectless'))){
                if(-not (Test-SamePath $instance.($pair[0]) (Join-Path $apiRoot $pair[1]))){throw '托管 API 目录与 apiRoot 不一致。'}
            }
        }
    }
    $config.stateDirectory=Get-FullDirectory $config.stateDirectory;Assert-NoReparsePoint $config.stateDirectory
    $official=@($config.instances | Where-Object {$_.role -eq 'official'})[0]
    $api=@($config.instances | Where-Object {$_.role -eq 'api'})[0]
    if(-not $official.profile){foreach($defaultRoot in @((Join-Path $env:APPDATA 'Codex'),(Join-Path $env:APPDATA 'ChatGPT'))){if(Test-PathOverlap $api.profile $defaultRoot){throw 'API profile 不能覆盖官方默认桌面数据目录。'}}}
    foreach($prior in $paths){if(Test-PathOverlap $config.stateDirectory $prior){throw '控制器运行记录目录不能与实例数据重叠。'}}
    return $config
}
function Get-ConfiguredProjectless([string]$HomePath) {
    $path=Join-Path $HomePath 'config.toml';Assert-NoReparsePoint $path
    $text=Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if($text -notmatch '(?ms)^\[desktop\]\s*\r?\n(?<section>.*?)(?=^\[|\z)'){throw '缺少 desktop 配置节。'}
    $section=$Matches.section
    if($section -match '(?m)^projectlessWorkspaceRoot\s*=\s*''([^'']+)''\s*$'){return Get-FullDirectory $Matches[1]}
    if($section -match '(?m)^projectlessWorkspaceRoot\s*=\s*"((?:[^"\\]|\\.)+)"\s*$'){return Get-FullDirectory ('"'+$Matches[1]+'"' | ConvertFrom-Json)}
    throw '无法安全解析 projectlessWorkspaceRoot；不会猜测任务目录。'
}
function Get-ProcessSnapshot {
    @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{Id=[int]$_.ProcessId;ParentId=[int]$_.ParentProcessId;Name=$_.Name;Path=$_.ExecutablePath;Command=$_.CommandLine;Started=if($_.CreationDate){$_.CreationDate.ToUniversalTime().Ticks.ToString()}else{''}}
    })
}
function Test-ProcessIdentity($Expected,$Actual) {
    return $null -ne $Actual -and $Expected.Id -eq $Actual.Id -and $Expected.Started -eq $Actual.Started -and
        (Test-SamePath $Expected.Path $Actual.Path) -and $Expected.Command -ceq $Actual.Command
}
function Resolve-Instance($Instance,$Snapshot,[string]$Executable,[scriptblock]$HomeReader = {param($n) [CodexDual.Native]::CodexHome($n)}) {
    $matches=@();$uncertain=@()
    foreach($candidate in $Snapshot) {
        if(-not (Test-SamePath $candidate.Path $Executable)){continue}
        if(-not $candidate.Command){$uncertain+=$candidate;continue}
        $argv=[CodexDual.Native]::Arguments($candidate.Command)
        if(@($argv | Where-Object {$_ -like '--type=*' -or $_ -eq '--type'}).Count){continue}
        try {
            $profile=Get-ProfileArgument $candidate.Command
            if($Instance.profile){if(-not (Test-SamePath $profile $Instance.profile)){continue}}
            elseif($profile){continue}
            $actualHome=& $HomeReader $candidate.Id
            if(-not $actualHome){$uncertain+=$candidate;continue}
            if(Test-SamePath $actualHome $Instance.home){$matches+=$candidate}else{$uncertain+=$candidate}
        } catch {$uncertain+=$candidate}
    }
    $state='Stopped';$reason='未运行'
    if($matches.Count -eq 1 -and $uncertain.Count -eq 0){$state='Running';$reason='运行中'}
    elseif($matches.Count -gt 1 -or $uncertain.Count -gt 0){$state='Unknown';$reason='状态未知：存在多个候选或不可读取的环境证据'}
    [pscustomobject]@{State=$state;Reason=$reason;Process=if($matches.Count -eq 1){$matches[0]}else{$null};Uncertain=$uncertain}
}
function Get-InstanceStatus($Config,$Instance) {
    $exe=Find-CodexExecutable $Instance.executable
    if(-not [CodexDual.Native]::IsGuiImage($exe)){throw '配置的程序不是 Windows GUI 桌面程序，不能使用 CLI 作为实例入口。'}
    $snapshot=Get-ProcessSnapshot
    # An old executable version still running must not disappear after a Store update.
    $paths=@($exe)
    $allowed=@($exe)
    $recordPath=Join-Path $Config.stateDirectory ($Instance.id+'.json')
    if(Test-Path -LiteralPath $recordPath){
        Assert-NoReparsePoint $recordPath
        $record=Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if($record.instanceId -eq $Instance.id -and (Test-SamePath $record.home $Instance.home)){
            $recorded=@($snapshot | Where-Object {$_.Id -eq $record.pid -and $_.Started -eq $record.started -and (Test-SamePath $_.Path $record.executable)})
            if($recorded.Count -eq 1){$allowed+=$record.executable}
        }
    }
    $otherPaths=@($snapshot | Where-Object {$_.Path -and [IO.Path]::GetFileName($_.Path) -in @('ChatGPT.exe','Codex.exe') -and $_.Path -ne $exe} | Select-Object -ExpandProperty Path -Unique)
    foreach($path in $otherPaths){if([CodexDual.Native]::IsGuiImage($path)){$paths+=$path}}
    $states=@($paths | Select-Object -Unique | ForEach-Object { Resolve-Instance $Instance $snapshot $_ })
    $running=@($states | Where-Object {$_.State -eq 'Running'})
    if(@($states | Where-Object {$_.State -eq 'Unknown'}).Count -or $running.Count -gt 1){throw '无法唯一核验实例归属；不会启动或操作进程。'}
    if($running.Count -eq 1){
        if(-not @($allowed | Where-Object {Test-SamePath $_ $running[0].Process.Path}).Count){throw '发现相同环境但未登记的可执行路径。可能为旧版本；请确认后设置 executable，不能按名称接管。'}
        return $running[0]
    }
    $unreadable=@($snapshot | Where-Object {-not $_.Path -and $_.Name -in @('ChatGPT.exe','Codex.exe')})
    if($unreadable.Count){throw '有无法读取可执行路径的 Codex 候选进程。'}
    return $states[0]
}
function Assert-CurrentIdentity($Instance,$Expected) {
    $actual=@(Get-ProcessSnapshot | Where-Object {$_.Id -eq $Expected.Id})
    if($actual.Count -ne 1 -or -not (Test-ProcessIdentity $Expected $actual[0])){throw '目标已退出或进程身份变化，请刷新状态。'}
    $resolved=Resolve-Instance $Instance $actual $Expected.Path
    if($resolved.State -ne 'Running'){throw '进程环境归属验证失败。'}
    return $actual[0]
}
function Assert-NotCurrentHost($Expected) {
    $snapshot=Get-ProcessSnapshot;$cursor=$PID;$seen=@{}
    while($cursor -and -not $seen.ContainsKey($cursor)) {
        if($cursor -eq $Expected.Id){throw '拒绝退出承载当前控制命令/开发任务的实例。请使用独立桌面控制器。'}
        $seen[$cursor]=$true;$p=@($snapshot | Where-Object {$_.Id -eq $cursor});if($p.Count -ne 1){break};$cursor=$p[0].ParentId
    }
}
function Save-InstanceRecord($Config,$Instance,$Process) {
    [void][IO.Directory]::CreateDirectory($Config.stateDirectory)
    Write-AtomicText (Join-Path $Config.stateDirectory ($Instance.id+'.json')) (@{instanceId=$Instance.id;home=$Instance.home;profile=$Instance.profile;launchMode=$Instance.launchMode;pid=$Process.Id;started=$Process.Started;executable=$Process.Path} | ConvertTo-Json)
}
function Invoke-InstanceLocked($Instance,[scriptblock]$Action) {
    # Profile/home based lock also serializes different controller configurations.
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Instance.home+'|'+$Instance.profile).ToLowerInvariant()))).Replace('-','')}finally{$sha.Dispose()}
    $mutex=New-Object Threading.Mutex($false,('Local\CodexDual.Instance.'+$hash));$held=$false
    try {try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(-not $held){throw '该实例正在处理另一个操作，请稍后重试。'};& $Action}
    finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Start-OrFindInstance($Config,$Instance) {
    Invoke-InstanceLocked $Instance {
        $status=Get-InstanceStatus $Config $Instance
        if($status.State -eq 'Running'){Save-InstanceRecord $Config $Instance $status.Process;return $status.Process}
        foreach($key in @('home','projects','projectless')){if($key -eq 'projectless' -and $Instance.role -eq 'official' -and -not $Instance.projectless -and (Get-ObjectValue $Instance 'projectlessMode' '') -eq 'inherit'){continue};if(-not (Test-Path -LiteralPath $Instance.$key -PathType Container)){throw "缺少目录：$key。请先完成部署。"}}
        if($Instance.profile -and -not (Test-Path -LiteralPath $Instance.profile -PathType Container)){throw 'Desktop profile 目录不存在。'}
        if($Instance.projectless -and -not (Test-SamePath (Get-ConfiguredProjectless $Instance.home) $Instance.projectless)){throw '实际无项目任务目录与控制器记录不符，请检查配置。'}
        if($Instance.launchMode -eq 'managed-api' -and (Get-ApiManagementMode $Instance.apiRoot) -eq 'builtin'){
            $profiles=Read-ApiProfiles $Config $Instance
            if($profiles.pendingProfile){[void](Apply-ApiProfile $Config $Instance $profiles.pendingProfile.id -UsePending)}
        }
        if($Instance.launchMode -eq 'external') {
            $launcher=Get-FullDirectory $Instance.externalLauncher;Assert-NoReparsePoint $launcher
            if(-not (Test-Path -LiteralPath $launcher -PathType Leaf)){throw '已有启动脚本不存在。'}
            $psi=New-Object Diagnostics.ProcessStartInfo
            $psi.FileName="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe";$psi.UseShellExecute=$false
            $psi.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$launcher+'"'
            foreach($name in @($psi.EnvironmentVariables.Keys)){if($name -match '^(CODEX_|OPENAI_|CHATGPT_|ELECTRON_)' -or $name -in @('CUSTOM_API_KEY','NODE_OPTIONS')){$psi.EnvironmentVariables.Remove($name)}}
        } else {
            $official=@($Config.instances | Where-Object {$_.role -eq 'official'})[0]
            $psi=New-CodexStartInfo -Executable (Find-CodexExecutable $Instance.executable) -OfficialHome $official.home -ApiRoot (Get-ObjectValue $Instance 'apiRoot' '') -Api:($Instance.launchMode -eq 'managed-api')
            $psi.EnvironmentVariables['CODEX_HOME']=$Instance.home
            $psi.WorkingDirectory=$Instance.projects
            $psi.Arguments=''
            if($Instance.profile){$psi.Arguments='--user-data-dir="'+$Instance.profile+'"'}
            $psi.EnvironmentVariables['CODEX_DUAL_INSTANCE_ID']=$Instance.id
        }
        try{[void][CodexDual.Native]::StartDetached($psi)}finally{$psi.EnvironmentVariables.Remove('CODEX_DUAL_API_KEY')}
        for($i=0;$i -lt 30;$i++) {
            Start-Sleep -Milliseconds 300
            $status=Get-InstanceStatus $Config $Instance
            if($status.State -eq 'Running'){Save-InstanceRecord $Config $Instance $status.Process;return $status.Process}
        }
        throw '启动后未能验证目标实例。不会重试启动；请检查原启动器与目录设置。'
    }
}
function Get-InstanceWindows($Instance,$Process) {
    [void](Assert-CurrentIdentity $Instance $Process)
    return @([CodexDual.Native]::Windows($Process.Id))
}
function Request-NativeInstanceActivation($Instance,$Process) {
    # Only use the packaged app's verified single-instance route. No credential is needed for forwarding.
    $storeExecutable=$null
    try{$storeExecutable=Find-CodexExecutable ''}catch{return $false}
    if(-not (Test-SamePath $Process.Path $storeExecutable)){return $false}
    Invoke-InstanceLocked $Instance {
        [void](Assert-CurrentIdentity $Instance $Process)
        $info=New-CodexStartInfo -Executable $Process.Path -OfficialHome $Instance.home
        $info.WorkingDirectory=$Instance.projects
        if($Instance.profile){$info.Arguments='--user-data-dir="'+$Instance.profile+'"'}
        $secondaryId=[CodexDual.Native]::StartDetached($info)
        for($attempt=0;$attempt -lt 20;$attempt++){
            Start-Sleep -Milliseconds 250
            if(-not (Get-Process -Id $secondaryId -ErrorAction SilentlyContinue)){
                [void](Assert-CurrentIdentity $Instance $Process)
                return $true
            }
        }
        throw '原生唤起请求未按预期退出；不会强行显示窗口或重试。请检查此桌面版本的单实例行为。'
    }
}
function Show-InstanceWindow($Instance,$Process,[long]$Handle) {
    [void](Assert-CurrentIdentity $Instance $Process)
    if(-not @([CodexDual.Native]::Windows($Process.Id) | Where-Object {$_.Handle -eq $Handle}).Count){throw '窗口已失效，请重新选择。'}
    return [CodexDual.Native]::FocusVisible($Handle,$Process.Id)
}
function Request-InstanceClose($Instance,$Process) {
    Assert-NotCurrentHost $Process
    [void](Assert-CurrentIdentity $Instance $Process)
    foreach($window in @(Get-InstanceWindows $Instance $Process)) {
        [void](Assert-CurrentIdentity $Instance $Process)
        [CodexDual.Native]::Close($window.Handle,$Process.Id)
    }
}
function Get-OwnedDesktopChildren($Process,$Snapshot) {
    $owned=@($Process);$changed=$true
    while($changed){$changed=$false;foreach($p in $Snapshot){
        if($p.Id -in $owned.Id -or -not (Test-SamePath $p.Path $Process.Path) -or $p.Command -notmatch '(?:^|\s)--type='){continue}
        $parent=@($owned | Where-Object {$_.Id -eq $p.ParentId})
        if($parent.Count -eq 1 -and [long]$p.Started -ge [long]$parent[0].Started){$owned+=$p;$changed=$true}
    }}
    return $owned
}
function Stop-VerifiedProcess($Expected) {
    $actual=@(Get-ProcessSnapshot | Where-Object {$_.Id -eq $Expected.Id})
    if($actual.Count -eq 0){return}
    if($actual.Count -ne 1 -or -not (Test-ProcessIdentity $Expected $actual[0])){throw '强制退出前进程身份已变化，已中止。'}
    # Hold a process handle, then verify its start time again: PID reuse cannot redirect Kill().
    $process=[Diagnostics.Process]::GetProcessById($Expected.Id)
    try {
        $handle=$process.Handle
        if([Math]::Abs($process.StartTime.ToUniversalTime().Ticks - [long]$Expected.Started) -ge 10){throw 'PID 已复用，已拒绝终止。'}
        $process.Kill()
    } finally {$process.Dispose()}
}
function Stop-InstanceForced($Instance,$Process,[switch]$UserConfirmed) {
    if(-not $UserConfirmed){throw '强制结束必须由用户明确确认，可能中断任务。'}
    Assert-NotCurrentHost $Process
    [void](Assert-CurrentIdentity $Instance $Process)
    $snapshot=Get-ProcessSnapshot;$owned=@(Get-OwnedDesktopChildren $Process $snapshot)
    # Deliberately exclude codex app-server, shells, editors and task servers.
    foreach($p in @($owned | Sort-Object { [long]$_.Started } -Descending)) {Stop-VerifiedProcess $p}
    return $owned
}
function Get-ExitResiduals($Before,$Owned) {
    $after=Get-ProcessSnapshot
    $desc=@($Owned);$changed=$true
    while($changed){$changed=$false;foreach($p in @($Before)+@($after)){
        $parents=@($desc | Where-Object {$_.Id -eq $p.ParentId -and [long]$_.Started -le [long]$p.Started})
        if($parents.Count -and -not @($desc | Where-Object {Test-ProcessIdentity $_ $p}).Count){$desc+=$p;$changed=$true}
    }}
    @($desc | Where-Object {$old=$_;@($after | Where-Object {Test-ProcessIdentity $old $_}).Count} | ForEach-Object {
        $candidate=$_
        [pscustomobject]@{Id=$_.Id;VerifiedDesktop=(@($Owned | Where-Object {Test-ProcessIdentity $_ $candidate}).Count -gt 0);Name=[IO.Path]::GetFileName($_.Path)}
    })
}
