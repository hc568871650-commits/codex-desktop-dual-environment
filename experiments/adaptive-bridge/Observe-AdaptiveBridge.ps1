[CmdletBinding()]
param([Parameter(Mandatory)][string]$IntegrationPath,[Parameter(Mandatory)][string]$IntegrationSha256,[int]$WaitSeconds=45)
# This process inherits the launcher environment. Discard every non-essential
# variable BEFORE loading modules or inspecting configuration. Do not load secrets.
$allowed=@('SystemRoot','WINDIR','PATH','TEMP','TMP','USERPROFILE','LOCALAPPDATA','APPDATA','COMSPEC','SystemDrive','NUMBER_OF_PROCESSORS','PROCESSOR_ARCHITECTURE','PROCESSOR_IDENTIFIER','PATHEXT','PSExecutionPolicyPreference')
foreach($entry in @(Get-ChildItem Env:)){if($entry.Name -notin $allowed){[Environment]::SetEnvironmentVariable($entry.Name,$null,'Process')}}
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Launch-AdaptiveBridge.ps1')
$integration=$null
try {
    $integration=Read-AbiIntegration $IntegrationPath $IntegrationSha256
    . (Join-Path $integration.controllerRoot 'src\Instances.ps1')
    . (Join-Path $integration.controllerRoot 'src\QuestionBridgeLaunch.ps1')
    . (Join-Path $integration.root 'AdaptiveBridge.ps1')
    $context=Import-AbiContext $integration
    if(-not(Test-AbiEnabled $integration $context.config)){Write-AbiStatus $integration 'disabled' 'USER_DISABLED';exit 0}
    $deadline=[DateTime]::UtcNow.AddSeconds([Math]::Min(60,[Math]::Max(1,$WaitSeconds)))
    $runtime=$null
    do {
        try {
            $status=Get-InstanceStatus $context.config $context.instance
            if($status.State -eq 'Running') {
                $binding=$null
                $registration=Join-Path $context.config.stateDirectory 'question-bridge.local.json'
                if(Test-Path -LiteralPath $registration){$saved=Read-AdaptiveJson $registration;if($saved.instanceId -eq $integration.instanceId){$binding=Get-ValidatedApiQuestionBridge -Directory $saved.directory -ApiHome $integration.apiHome -Profile $integration.profile -DesktopExecutable $status.Process.Path -InstanceId $integration.instanceId}}
                $runtime=Get-AdaptiveBridgeRuntime -Instance $context.instance -Snapshot (Get-ProcessSnapshot) -DesktopExecutable $status.Process.Path -ValidatedBinding $binding
            }
        }catch{$runtime=$null}
        if(-not $runtime){Start-Sleep -Milliseconds 500}
    }while(-not $runtime -and [DateTime]::UtcNow -lt $deadline)
    if(-not $runtime){throw 'OWNED_RUNTIME_NOT_READY'}
    if(-not(Test-AbiEnabled $integration $context.config)){Write-AbiStatus $integration 'disabled' 'USER_DISABLED';exit 0}
    # Preparation creates immutable candidates only. It never changes the
    # controller's live question binding or restarts the application.
    $result=Invoke-AdaptiveBridgeUpdate -Root $integration.root -Instance $context.instance -Runtime $runtime -ProxyPath $integration.proxyPath -CompatibilityScript $integration.compatibilityScript
    $result|ConvertTo-Json -Depth 8
}catch {
    if($integration){try{Write-AbiStatus $integration 'needs_adaptation' ('OBSERVE_FALLBACK: '+$_.Exception.Message)}catch{}}
    exit 1
}
