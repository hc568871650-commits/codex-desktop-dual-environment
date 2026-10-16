# Preparation only. This module never restarts Desktop or changes an active binding.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:AdaptiveBridgeModulePath=$PSCommandPath
if(-not (Get-Command Resolve-Instance -ErrorAction SilentlyContinue)){. "$PSScriptRoot\..\..\src\Instances.ps1"}
if(-not (Get-Command Get-ApiQuestionBridgeValidation -ErrorAction SilentlyContinue)){. "$PSScriptRoot\..\..\src\QuestionBridgeLaunch.ps1"}

function Get-AdaptivePlainPath([string]$Path) {
    if(-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')){throw 'PATH_UNSAFE'}
    $value=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    Assert-NoReparsePoint $value
    return [string]$value
}
function Read-AdaptiveJson([string]$Path) {
    $path=Get-AdaptivePlainPath $Path
    $info=Get-Item -LiteralPath $path -ErrorAction Stop
    if($info.Length -gt 262144){throw 'JSON_OVERSIZE'}
    $raw=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    $value=ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    if($null -eq $value -or $value -isnot [pscustomobject]){throw 'JSON_INVALID'}
    return $value
}
function Write-AdaptiveJson([string]$Path,$Value) {
    # Callers construct plain hashtables; never serialize FileInfo/ETS objects.
    Write-AtomicText (Get-AdaptivePlainPath $Path) (ConvertTo-Json -InputObject $Value -Depth 15)
}
function Get-AdaptiveHash([string]$Path){return [string](Get-FileHash -LiteralPath (Get-AdaptivePlainPath $Path) -Algorithm SHA256).Hash}
function Get-AdaptiveTextHash([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Test-AdaptiveCompatibilityReport {
    param($Report,[string]$CliHash,[string]$ProxyHash)
    try {
        if($Report.schema -ne 1 -or $Report.success -isnot [bool] -or -not $Report.success -or $Report.suiteVersion -cne 'adaptive-protocol-v1' -or $Report.cliHash -ne $CliHash -or $Report.proxyHash -ne $ProxyHash){return $false}
        foreach($name in @('sync','async','multiconnection')){
            $checks=@($Report.checks|Where-Object {$_.name -ceq $name})
            if($checks.Count -ne 1 -or $checks[0].success -isnot [bool] -or -not $checks[0].success){return $false}
        }
        return $true
    }catch{return $false}
}
function Test-AdaptiveBridgeCandidate {
    param([string]$Root,$Instance,[string]$CandidateDirectory,[string]$DesktopExecutable,[string]$ProxyPath='',[string]$CompatibilityScript='')
    try {
        $root=Get-AdaptivePlainPath $Root;$candidate=Get-AdaptivePlainPath $CandidateDirectory
        $versions=(Join-Path $root 'versions')+'\'
        if(-not $candidate.StartsWith($versions,[StringComparison]::OrdinalIgnoreCase)){return $null}
        if(Test-Path -LiteralPath (Join-Path $root 'DISABLED')){return $null}
        $valid=Get-ApiQuestionBridgeValidation -Directory $candidate -ApiHome $Instance.home -Profile $Instance.profile -DesktopExecutable $DesktopExecutable -InstanceId $Instance.id
        if(-not $valid.valid){return $null}
        $report=Read-AdaptiveJson (Join-Path $candidate 'report.json')
        if(-not (Test-AdaptiveCompatibilityReport $report $valid.binding.manifest.realCliHash $valid.binding.manifest.proxyHash)){return $null}
        $expectedFingerprint=''
        if($ProxyPath -and $CompatibilityScript){
            $runtime=[pscustomobject]@{desktopExe=$DesktopExecutable;realCli=$valid.binding.manifest.realCli}
            $expectedFingerprint=(Get-AdaptiveBridgeFingerprint $Instance $runtime $ProxyPath $CompatibilityScript).fingerprint
        }elseif($ProxyPath -or $CompatibilityScript){return $null}
        $leaf=[IO.Path]::GetFileName($candidate)
        if($leaf -notmatch '^([a-f0-9]{64})-[a-f0-9]{32}$'){return $null}
        $recordFingerprint=[string]$Matches[1]
        if($expectedFingerprint -and $recordFingerprint -ne $expectedFingerprint){return $null}
        $cache=Read-AdaptiveJson (Join-Path (Join-Path $root 'cache') ($recordFingerprint+'.json'))
        if($cache.schema -ne 1 -or $cache.status -ne 'ready' -or $cache.fingerprint -ne $recordFingerprint -or -not (Test-SamePath $cache.candidateDirectory $candidate) -or $cache.reportHash -ne (Get-AdaptiveHash (Join-Path $candidate 'report.json'))){return $null}
        return $valid.binding
    }catch{return $null}
}
function Get-AdaptiveBridgeRuntime {
    param($Instance,$Snapshot,[string]$DesktopExecutable,[scriptblock]$HomeReader={param($n) [CodexDual.Native]::CodexHome($n)},$ValidatedBinding=$null)
    if($Instance.role -ne 'api' -or $Instance.id -notmatch '^[a-f0-9]{32}$'){throw 'API_IDENTITY_REQUIRED'}
    $resolved=Resolve-Instance $Instance $Snapshot $DesktopExecutable $HomeReader
    if($resolved.State -ne 'Running'){throw 'API_RUNTIME_NOT_UNIQUE'}
    $desktop=$resolved.Process
    $children=@($Snapshot|Where-Object {$_.ParentId -eq $desktop.Id})
    $eligible=@();$bridge=$null
    foreach($child in $children){
        if($child.Path -and [IO.Path]::GetFileName($child.Path) -ieq 'codex.exe'){$eligible+=$child}
    }
    if($ValidatedBinding){
        # Revalidate supplied binding; callers cannot bless an arbitrary descendant.
        $checked=Get-ValidatedApiQuestionBridge -Directory $ValidatedBinding.directory -ApiHome $Instance.home -Profile $Instance.profile -DesktopExecutable $DesktopExecutable -InstanceId $Instance.id
        if($checked){
            $bridges=@($children|Where-Object {Test-SamePath $_.Path $checked.proxy})
            if($bridges.Count -gt 1){throw 'BRIDGE_RUNTIME_NOT_UNIQUE'}
            if($bridges.Count -eq 1){
                $bridge=$bridges[0]
                $eligible+=@($Snapshot|Where-Object {$_.ParentId -eq $bridge.Id -and (Test-SamePath $_.Path $checked.manifest.realCli)})
            }
        }
    }
    if($eligible.Count -ne 1){throw 'CLI_RUNTIME_NOT_UNIQUE'}
    $cli=$eligible[0]
    if(-not $desktop.Started -or -not $cli.Started -or [long]$cli.Started -lt [long]$desktop.Started){throw 'PROCESS_IDENTITY_INVALID'}
    if($bridge -and (-not $bridge.Started -or [long]$bridge.Started -lt [long]$desktop.Started -or [long]$cli.Started -lt [long]$bridge.Started)){throw 'BRIDGE_PROCESS_IDENTITY_INVALID'}
    if(-not (Test-SamePath (& $HomeReader $cli.Id) $Instance.home)){throw 'CLI_HOME_MISMATCH'}
    $args=[CodexDual.Native]::Arguments($cli.Command)
    if($args -notcontains 'app-server'){throw 'CLI_NOT_APP_SERVER'}
    return [pscustomobject]@{desktopExe=(Get-AdaptivePlainPath $desktop.Path);realCli=(Get-AdaptivePlainPath $cli.Path);desktopProcess=$desktop;cliProcess=$cli;bridgeProcess=$bridge;instanceId=[string]$Instance.id;apiHome=(Get-AdaptivePlainPath $Instance.home);profile=(Get-AdaptivePlainPath $Instance.profile)}
}
function Get-AdaptiveBridgeFingerprint {
    param($Instance,$Runtime,[string]$ProxyPath,[string]$CompatibilityScript)
    $parts=[ordered]@{schema=1;protocol='adaptive-question-fixture-v1';instanceId=[string]$Instance.id;apiHome=(Get-AdaptivePlainPath $Instance.home).ToLowerInvariant();profile=(Get-AdaptivePlainPath $Instance.profile).ToLowerInvariant();desktopExe=(Get-AdaptivePlainPath $Runtime.desktopExe).ToLowerInvariant();realCli=(Get-AdaptivePlainPath $Runtime.realCli).ToLowerInvariant();desktopHash=(Get-AdaptiveHash $Runtime.desktopExe);cliHash=(Get-AdaptiveHash $Runtime.realCli);proxyHash=(Get-AdaptiveHash $ProxyPath);fixtureHash=(Get-AdaptiveHash $CompatibilityScript)}
    $parts['coreHash']=Get-AdaptiveHash $script:AdaptiveBridgeModulePath
    $fixtureExe=Join-Path ([IO.Path]::GetDirectoryName($CompatibilityScript)) 'bin\RealCliQuestionFixture.exe'
    $parts['fixtureBinaryHash']=if(Test-Path -LiteralPath $fixtureExe){Get-AdaptiveHash $fixtureExe}else{'absent'}
    return [pscustomobject]@{fingerprint=(Get-AdaptiveTextHash (ConvertTo-Json -InputObject $parts -Compress));parts=$parts}
}
function Invoke-AdaptiveBridgeUpdate {
    param([string]$Root,$Instance,$Runtime,[string]$ProxyPath,[string]$CompatibilityScript,[int]$FailureCooldownSeconds=1800,[scriptblock]$CompatibilityRunner=$null)
    $root=Get-AdaptivePlainPath $Root
    if($Instance.role -ne 'api' -or $Instance.id -notmatch '^[a-f0-9]{32}$'){throw 'API_IDENTITY_REQUIRED'}
    $identity=([string]$Instance.id+'|'+(Get-AdaptivePlainPath $Instance.home)+'|'+(Get-AdaptivePlainPath $Instance.profile)).ToLowerInvariant()
    $mutex=New-Object Threading.Mutex($false,('Local\CodexDual.Adaptive.'+(Get-AdaptiveTextHash $identity)))
    $held=$false
    try {
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){return [pscustomobject]@{schema=1;state='validating';reason='VALIDATION_ALREADY_RUNNING';candidateDirectory=''}}
        [void][IO.Directory]::CreateDirectory($root)
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'state'))
        $statusPath=Join-Path (Join-Path $root 'state') 'status.json'
        $state=[ordered]@{schema=1;state='needs_adaptation';reason='UNVALIDATED';instanceId=[string]$Instance.id;apiHome=(Get-AdaptivePlainPath $Instance.home);profile=(Get-AdaptivePlainPath $Instance.profile);fingerprint='';candidateDirectory='';updatedUtc=[DateTime]::UtcNow.ToString('o')}
        if(Test-Path -LiteralPath (Join-Path $root 'DISABLED')){$state.state='disabled';$state.reason='USER_DISABLED';Write-AdaptiveJson $statusPath $state;return [pscustomobject]$state}
        try {
            if($Runtime.instanceId -ne $Instance.id -or -not (Test-SamePath $Runtime.apiHome $Instance.home) -or -not (Test-SamePath $Runtime.profile $Instance.profile)){throw 'RUNTIME_IDENTITY_MISMATCH'}
            $fp=Get-AdaptiveBridgeFingerprint $Instance $Runtime $ProxyPath $CompatibilityScript
            $state.fingerprint=$fp.fingerprint
            $cacheRoot=Join-Path $root 'cache';[void][IO.Directory]::CreateDirectory($cacheRoot)
            $cachePath=Join-Path $cacheRoot ($fp.fingerprint+'.json')
            if(Test-Path -LiteralPath $cachePath){
                try {
                    $cache=Read-AdaptiveJson $cachePath
                    if($cache.schema -ne 1 -or $cache.fingerprint -ne $fp.fingerprint){throw 'CACHE_SCHEMA_INVALID'}
                    $failedAt=if($cache.status -eq 'failed'){[DateTime]::Parse($cache.failedUtc).ToUniversalTime()}else{[DateTime]::MinValue}
                    if($failedAt -gt [DateTime]::UtcNow.AddMinutes(1)){throw 'CACHE_TIME_INVALID'}
                    if($cache.status -eq 'failed' -and [DateTime]::UtcNow -lt $failedAt.AddSeconds([Math]::Max(60,[Math]::Min(86400,$FailureCooldownSeconds)))){
                        $state.reason='COMPATIBILITY_FAILED_COOLDOWN';Write-AdaptiveJson $statusPath $state;return [pscustomobject]$state
                    }
                    if($cache.status -eq 'ready'){
                        if(-not (Test-AdaptiveBridgeCandidate -Root $root -Instance $Instance -CandidateDirectory $cache.candidateDirectory -DesktopExecutable $Runtime.desktopExe -ProxyPath $ProxyPath -CompatibilityScript $CompatibilityScript)){throw 'CACHE_CANDIDATE_INVALID'}
                        $valid=Get-ApiQuestionBridgeValidation -Directory $cache.candidateDirectory -ApiHome $Instance.home -Profile $Instance.profile -DesktopExecutable $Runtime.desktopExe -InstanceId $Instance.id
                        $report=Read-AdaptiveJson (Join-Path $cache.candidateDirectory 'report.json')
                        if($valid.valid -and (Test-AdaptiveCompatibilityReport $report $fp.parts.cliHash $fp.parts.proxyHash) -and $cache.reportHash -eq (Get-AdaptiveHash (Join-Path $cache.candidateDirectory 'report.json'))){
                            $state.state='waiting_restart';$state.reason='COMPATIBLE_PREPARED';$state.candidateDirectory=[string]$cache.candidateDirectory
                            $bridgeProcess=Get-ObjectValue $Runtime 'bridgeProcess' $null
                            if($bridgeProcess -and (Test-SamePath $bridgeProcess.Path $valid.binding.proxy)){$state.state='normal';$state.reason='BOUND_NOT_CONNECTED'}
                            Write-AdaptiveJson $statusPath $state;return [pscustomobject]$state
                        }
                        throw 'CACHE_EVIDENCE_INVALID'
                    }
                    if($cache.status -notin @('ready','failed')){throw 'CACHE_STATUS_INVALID'}
                }catch {
                    # Preserve damaged evidence; it must never count as a compatibility pass.
                    [IO.File]::Move($cachePath,($cachePath+'.invalid.'+[Guid]::NewGuid().ToString('N')))
                }
            }
            $state.state='validating';$state.reason='LOCAL_FIXTURE_RUNNING';Write-AdaptiveJson $statusPath $state
            $runRoot=Join-Path $root ('validation-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($runRoot)
            if($CompatibilityRunner){& $CompatibilityRunner $Runtime.realCli $ProxyPath $runRoot | Out-Null}
            else {& $CompatibilityScript -CliPath $Runtime.realCli -ProxyPath $ProxyPath -OutputDirectory $runRoot | Out-Null}
            $report=Read-AdaptiveJson (Join-Path $runRoot 'report.json')
            if(-not (Test-AdaptiveCompatibilityReport $report $fp.parts.cliHash $fp.parts.proxyHash)){throw 'COMPATIBILITY_REPORT_REJECTED'}
            $after=Get-AdaptiveBridgeFingerprint $Instance $Runtime $ProxyPath $CompatibilityScript
            if($after.fingerprint -ne $fp.fingerprint){throw 'RUNTIME_CHANGED_DURING_VALIDATION'}
            if(Test-Path -LiteralPath (Join-Path $root 'DISABLED')){throw 'USER_DISABLED_DURING_VALIDATION'}
            $versions=Join-Path $root 'versions';[void][IO.Directory]::CreateDirectory($versions)
            $candidate=Join-Path $versions ($fp.fingerprint+'-'+[Guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($candidate)
            $id=[Guid]::NewGuid().ToString('N')
            Copy-Item -LiteralPath $ProxyPath -Destination (Join-Path $candidate 'BridgeProxy.exe')
            Copy-Item -LiteralPath (Join-Path $runRoot 'report.json') -Destination (Join-Path $candidate 'report.json')
            $config=[ordered]@{realCli=[string]$Runtime.realCli;apiHome=[string]$state.apiHome;pipeName=('codex-api-questions-'+$id);instanceId=('api-live-'+$id);takeoverQuestions=$true;multiConnection=$true}
            Write-AdaptiveJson (Join-Path $candidate 'bridge.config.json') $config
            $binding=[ordered]@{schema=1;kind='api-question-bridge-installation';id=$id;controllerInstanceId=[string]$Instance.id;userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;root=$candidate;apiHome=[string]$state.apiHome;profile=[string]$state.profile;realCli=[string]$Runtime.realCli;realCliHash=$fp.parts.cliHash;desktopExe=[string]$Runtime.desktopExe;desktopHash=$fp.parts.desktopHash;proxyHash=$fp.parts.proxyHash;configHash=(Get-AdaptiveHash (Join-Path $candidate 'bridge.config.json'));createdUtc=[DateTime]::UtcNow.ToString('o')}
            Write-AdaptiveJson (Join-Path $candidate 'binding.json') $binding
            $checked=Get-ApiQuestionBridgeValidation -Directory $candidate -ApiHome $Instance.home -Profile $Instance.profile -DesktopExecutable $Runtime.desktopExe -InstanceId $Instance.id
            if(-not $checked.valid){throw ('PREPARED_BINDING_INVALID_'+$checked.reasonCode)}
            Write-AdaptiveJson $cachePath @{schema=1;fingerprint=$fp.fingerprint;status='ready';candidateDirectory=$candidate;reportHash=(Get-AdaptiveHash (Join-Path $candidate 'report.json'));validatedUtc=[DateTime]::UtcNow.ToString('o')}
            $state.state='waiting_restart';$state.reason='COMPATIBLE_PREPARED';$state.candidateDirectory=$candidate
        } catch {
            $state.state='needs_adaptation';$state.reason='VALIDATION_FAILED';$state.candidateDirectory=''
            if(Test-Path -LiteralPath (Join-Path $root 'DISABLED')){$state.state='disabled';$state.reason='USER_DISABLED'}
            if($state.fingerprint){Write-AdaptiveJson (Join-Path (Join-Path $root 'cache') ($state.fingerprint+'.json')) @{schema=1;fingerprint=$state.fingerprint;status='failed';failedUtc=[DateTime]::UtcNow.ToString('o');retryAfterUtc=[DateTime]::UtcNow.AddSeconds([Math]::Max(60,[Math]::Min(86400,$FailureCooldownSeconds))).ToString('o');reason=([string]$_.Exception.Message).Substring(0,[Math]::Min(240,([string]$_.Exception.Message).Length))}}
        }
        $state.updatedUtc=[DateTime]::UtcNow.ToString('o');Write-AdaptiveJson $statusPath $state
        return [pscustomobject]$state
    } finally {if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
