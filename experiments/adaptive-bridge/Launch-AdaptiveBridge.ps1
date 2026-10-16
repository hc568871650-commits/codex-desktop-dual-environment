# Dot-source only. The launcher pins this file and integration.json before loading it.
Set-StrictMode -Version Latest
function Get-AbiHash([string]$Path) { return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash }
function Assert-AbiPlainPath([string]$Path) {
    if(-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')){throw 'ADAPTIVE_PATH_UNSAFE'}
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){
        if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'ADAPTIVE_REPARSE_PATH'}
        $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
    }
}
function Test-AbiPath([string]$A,[string]$B) {
    if(-not $A -or -not $B){return $false}
    return [IO.Path]::GetFullPath($A).TrimEnd('\','/').Equals([IO.Path]::GetFullPath($B).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)
}
function Write-AbiJson([string]$Path,$Value) {
    Assert-AbiPlainPath $Path
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($Value|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding($false)))
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
    } finally {if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function Read-AbiIntegration([string]$Path,[string]$Sha256) {
    Assert-AbiPlainPath $Path
    if($Sha256 -notmatch '^[0-9a-fA-F]{64}$' -or (Get-AbiHash $Path) -ne $Sha256){throw 'ADAPTIVE_INTEGRATION_CHANGED'}
    $value=[IO.File]::ReadAllText($Path)|ConvertFrom-Json
    if($value.schema -ne 1 -or $value.instanceId -notmatch '^[a-f0-9]{32}$' -or -not(Test-AbiPath $value.root (Split-Path -Parent $Path))){throw 'ADAPTIVE_INTEGRATION_INVALID'}
    foreach($entry in @($value.bundleFiles)) {
        if([IO.Path]::IsPathRooted($entry.path) -or $entry.path -match '(^|[\\/])\.\.([\\/]|$)'){throw 'ADAPTIVE_BUNDLE_PATH'}
        $file=Join-Path $value.root $entry.path;Assert-AbiPlainPath $file
        if((Get-AbiHash $file) -ne $entry.sha256){throw 'ADAPTIVE_BUNDLE_CHANGED'}
    }
    foreach($entry in @($value.dependencies)) { Assert-AbiPlainPath $entry.path;if((Get-AbiHash $entry.path) -ne $entry.sha256){throw 'ADAPTIVE_DEPENDENCY_CHANGED'} }
    return $value
}
function Import-AbiContext($Integration) {
    . (Join-Path $Integration.controllerRoot 'src\Instances.ps1')
    . (Join-Path $Integration.controllerRoot 'src\QuestionBridgeLaunch.ps1')
    $config=Read-ControllerConfig $Integration.controllerConfig
    $instance=Get-ApiFeatureInstance $config $Integration.instanceId
    if(-not $instance -or -not(Test-SamePath $instance.home $Integration.apiHome) -or -not(Test-SamePath $instance.profile $Integration.profile) -or -not(Test-SamePath $instance.externalLauncher $Integration.launcher)){throw 'ADAPTIVE_INSTANCE_CHANGED'}
    return [pscustomobject]@{config=$config;instance=$instance}
}
function Write-AbiStatus($Integration,[string]$State,[string]$Reason,[string]$Candidate='',[string]$Fingerprint='') {
    Write-AbiJson (Join-Path $Integration.root 'state\status.json') @{schema=1;state=$State;reason=$Reason;instanceId=$Integration.instanceId;apiHome=$Integration.apiHome;profile=$Integration.profile;candidateDirectory=$Candidate;fingerprint=$Fingerprint;updatedUtc=[DateTime]::UtcNow.ToString('o')}
}
function Test-AbiEnabled($Integration,$Config) {
    if(Test-Path -LiteralPath (Join-Path $Integration.root 'DISABLED')){return $false}
    if($Integration.legacyBridgeDirectory -and (Test-Path -LiteralPath (Join-Path $Integration.legacyBridgeDirectory 'DISABLED'))){return $false}
    $registration=Join-Path $Config.stateDirectory 'adaptive-bridge.local.json';Assert-AbiPlainPath $registration
    if(-not(Test-Path -LiteralPath $registration)){return $false}
    $saved=[IO.File]::ReadAllText($registration)|ConvertFrom-Json
    if($saved.schema -ne 1 -or $saved.instanceId -ne $Integration.instanceId -or -not(Test-AbiPath $saved.root $Integration.root)){throw 'ADAPTIVE_REGISTRATION_CHANGED'}
    return ($saved.enabled -is [bool] -and $saved.enabled)
}
function Assert-AbiStopped($Integration,$Context) {
    $status=Get-InstanceStatus $Context.config $Context.instance
    if($status.State -ne 'Stopped'){throw 'ADAPTIVE_INSTANCE_NOT_STOPPED'}
    # Any bridge process prevents rebinding, including orphaned/answer-owning bridges.
    # Unreadable candidates also block; never infer that there are no owned questions.
    foreach($process in @(Get-ProcessSnapshot)) {
        if($process.Name -ieq 'BridgeProxy.exe' -or ($process.Path -and [IO.Path]::GetFileName($process.Path) -ieq 'BridgeProxy.exe')) {
            if(-not $process.Path -or $process.Path.StartsWith($Integration.root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or ($Integration.legacyBridgeDirectory -and (Test-AbiPath (Split-Path -Parent $process.Path) $Integration.legacyBridgeDirectory))){throw 'ADAPTIVE_OWNED_BRIDGE_RUNNING'}
        }
    }
}
function Set-AbiControllerBinding($Integration,$Context,$Binding) {
    Assert-AbiStopped $Integration $Context
    $path=Join-Path $Context.config.stateDirectory 'question-bridge.local.json';Assert-AbiPlainPath $path
    $prior=if(Test-Path -LiteralPath $path){[IO.File]::ReadAllText($path)}else{$null}
    if($prior){$old=$prior|ConvertFrom-Json;if($old.schema -ne 1 -or $old.instanceId -ne $Integration.instanceId){throw 'ADAPTIVE_PREVIOUS_BINDING_INVALID'};if(Test-Path -LiteralPath (Join-Path $old.directory 'DISABLED')){throw 'ADAPTIVE_PREVIOUS_BINDING_DISABLED'}}
    $next=@{schema=1;directory=$Binding.directory;instanceId=$Integration.instanceId}
    # Write-ahead recovery record. A crash never launches a half-selected proxy;
    # the next startup revalidates and either completes this registration or stays native.
    $journal=Join-Path $Integration.root 'state\promotion.json'
    Write-AbiJson $journal @{schema=1;state='prepared';path=$path;previousText=$prior;next=$next;updatedUtc=[DateTime]::UtcNow.ToString('o')}
    Assert-AbiStopped $Integration $Context
    if(-not(Test-AbiEnabled $Integration $Context.config)){throw 'ADAPTIVE_DISABLED_DURING_PROMOTION'}
    if(($null -ne $prior) -ne (Test-Path -LiteralPath $path)){throw 'ADAPTIVE_BINDING_CONCURRENT_CHANGE'}
    if($null -ne $prior -and [IO.File]::ReadAllText($path) -cne $prior){throw 'ADAPTIVE_BINDING_CONCURRENT_CHANGE'}
    Write-AbiJson $path $next
    $saved=[IO.File]::ReadAllText($path)|ConvertFrom-Json
    if($saved.instanceId -ne $Integration.instanceId -or -not(Test-AbiPath $saved.directory $Binding.directory)){throw 'ADAPTIVE_BINDING_WRITE_FAILED'}
    Write-AbiJson $journal @{schema=1;state='committed';path=$path;previousText=$prior;next=$next;updatedUtc=[DateTime]::UtcNow.ToString('o')}
}
function Get-AdaptiveBridgeLaunch {
    param([string]$IntegrationPath,[string]$IntegrationSha256,[string]$ApiHome,[string]$Profile,[string]$DesktopExecutable)
    Remove-Item Env:\CODEX_CLI_PATH -ErrorAction SilentlyContinue
    $integration=$null;$held=$false;$mutex=$null
    try {
        $integration=Read-AbiIntegration $IntegrationPath $IntegrationSha256
        if(-not(Test-AbiPath $ApiHome $integration.apiHome) -or -not(Test-AbiPath $Profile $integration.profile)){throw 'ADAPTIVE_LAUNCH_IDENTITY_MISMATCH'}
        # These imports must be in this scope; functions imported inside a helper
        # function are intentionally not assumed to survive that function's return.
        . (Join-Path $integration.controllerRoot 'src\Instances.ps1')
        . (Join-Path $integration.controllerRoot 'src\QuestionBridgeLaunch.ps1')
        . (Join-Path $integration.root 'AdaptiveBridge.ps1')
        $context=Import-AbiContext $integration
        if(-not(Test-AbiEnabled $integration $context.config)){Write-AbiStatus $integration 'disabled' 'USER_DISABLED';return $null}
        $mutex=New-Object Threading.Mutex($false,('Local\CodexAdaptivePromotion-'+$integration.instanceId))
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){return $null}
        Assert-AbiStopped $integration $context
        $statusPath=Join-Path $integration.root 'state\status.json'
        if(-not(Test-Path -LiteralPath $statusPath)){Write-AbiStatus $integration 'needs_adaptation' 'FIRST_NATIVE_LAUNCH';return $null}
        $status=Read-AdaptiveJson $statusPath
        if($status.schema -ne 1 -or $status.instanceId -ne $integration.instanceId -or -not(Test-AbiPath $status.apiHome $ApiHome) -or -not(Test-AbiPath $status.profile $Profile)){throw 'ADAPTIVE_STATUS_IDENTITY_MISMATCH'}
        if($status.state -notin @('waiting_restart','normal') -or -not $status.candidateDirectory){return $null}
        $binding=Test-AdaptiveBridgeCandidate -Root $integration.root -Instance $context.instance -CandidateDirectory $status.candidateDirectory -DesktopExecutable $DesktopExecutable -ProxyPath $integration.proxyPath -CompatibilityScript $integration.compatibilityScript
        if(-not $binding){throw 'ADAPTIVE_CANDIDATE_INVALID'}
        Set-AbiControllerBinding $integration $context $binding
        # Environment selection occurs only after atomic controller registration.
        if(-not(Test-AbiEnabled $integration $context.config)){throw 'ADAPTIVE_DISABLED_DURING_PROMOTION'}
        $env:CODEX_CLI_PATH=$binding.proxy
        Write-AbiStatus $integration 'normal' 'BOUND_NOT_CONNECTED' $binding.directory $status.fingerprint
        return $binding
    } catch {
        Remove-Item Env:\CODEX_CLI_PATH -ErrorAction SilentlyContinue
        if($integration){try{Write-AbiStatus $integration 'needs_adaptation' ('LAUNCH_FALLBACK: '+$_.Exception.Message)}catch{}}
        return $null
    } finally {if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
}
