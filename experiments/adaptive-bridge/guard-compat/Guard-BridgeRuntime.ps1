[CmdletBinding()]
param([Parameter(Mandatory)][string]$ApiHome,[Parameter(Mandatory)][string]$Profile,[Parameter(Mandatory)][string]$DesktopIds)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
try {
    if($DesktopIds -notmatch '^\d+(,\d+)*$'){throw 'DESKTOP_IDS_INVALID'}
    $bindingPath=Join-Path $PSScriptRoot 'guard-runtime-binding.json'
    if((Get-Item -LiteralPath $bindingPath).Length -gt 8192){throw 'BINDING_OVERSIZE'}
    $binding=[IO.File]::ReadAllText($bindingPath)|ConvertFrom-Json
    if($binding.schema -ne 1 -or $binding.integrationHash -notmatch '^[a-fA-F0-9]{64}$' -or $binding.launchHelperHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'BINDING_INVALID'}
    $helper=Join-Path (Split-Path $binding.integrationPath -Parent) 'Launch-AdaptiveBridge.ps1'
    foreach($path in @($bindingPath,$helper,$binding.integrationPath)){
        if(-not [IO.Path]::IsPathRooted($path) -or $path.StartsWith('\\')){throw 'PATH_UNSAFE'}
        $cursor=[IO.Path]::GetFullPath($path)
        while($cursor){if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'PATH_REPARSE'};$cursor=Split-Path $cursor -Parent}
    }
    if((Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash -ne $binding.launchHelperHash){throw 'HELPER_CHANGED'}
    . $helper
    $integration=Read-AbiIntegration $binding.integrationPath $binding.integrationHash
    if(-not (Test-AbiPath $ApiHome $integration.apiHome) -or -not (Test-AbiPath $Profile $integration.profile)){throw 'IDENTITY_MISMATCH'}
    . (Join-Path $integration.controllerRoot 'src\Instances.ps1')
    . (Join-Path $integration.controllerRoot 'src\QuestionBridgeLaunch.ps1')
    . (Join-Path $integration.root 'AdaptiveBridge.ps1')
    $context=Import-AbiContext $integration
    $status=Get-InstanceStatus $context.config $context.instance
    $ids=@($DesktopIds.Split(',')|ForEach-Object {[int]$_})
    if($status.State -ne 'Running' -or $ids -notcontains [int]$status.Process.Id){throw 'DESKTOP_CHANGED'}
    $registration=Read-AdaptiveJson (Join-Path $context.config.stateDirectory 'question-bridge.local.json')
    if($registration.schema -ne 1 -or $registration.instanceId -cne $integration.instanceId){throw 'REGISTRATION_CHANGED'}
    $verified=Get-ValidatedApiQuestionBridge -Directory $registration.directory -ApiHome $ApiHome -Profile $Profile -DesktopExecutable $status.Process.Path -InstanceId $integration.instanceId
    if(-not $verified){throw 'BINDING_UNVERIFIED'}
    $runtime=Get-AdaptiveBridgeRuntime -Instance $context.instance -Snapshot (Get-ProcessSnapshot) -DesktopExecutable $status.Process.Path -ValidatedBinding $verified
    if(-not $runtime.bridgeProcess){throw 'BRIDGE_NOT_RUNNING'}
    # PID/start/path/command and Home/profile rechecked after all hashes, before
    # returning process metadata. No chat, logs, auth or project content is read.
    [void](Assert-CurrentIdentity $context.instance $runtime.desktopProcess)
    if(-not (Test-ExpectedProcessAlive $runtime.bridgeProcess) -or -not (Test-ExpectedProcessAlive $runtime.cliProcess)){throw 'PROCESS_CHANGED'}
    $started=[DateTimeOffset]::new([DateTime]::new([long]$runtime.cliProcess.Started,[DateTimeKind]::Utc)).ToUnixTimeSeconds()
    $row=@{ProcessId=[int]$runtime.cliProcess.Id;ParentProcessId=[int]$runtime.cliProcess.ParentId;DesktopProcessId=[int]$runtime.desktopProcess.Id;BridgeProcessId=[int]$runtime.bridgeProcess.Id;ExecutablePath=[string]$runtime.realCli;Started=[long]$started;VerifiedBridge=$true}
    @{schema=1;apiHome=[string]$ApiHome;profile=[string]$Profile;rows=@($row)}|ConvertTo-Json -Depth 5 -Compress
} catch {
    # Unknown or stale evidence is an empty observation, never a heuristic walk.
    @{schema=1;apiHome=[string]$ApiHome;profile=[string]$Profile;rows=@()}|ConvertTo-Json -Depth 5 -Compress
    exit 1
}
