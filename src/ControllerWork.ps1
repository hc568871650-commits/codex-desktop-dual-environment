# Runs in a dedicated runspace; never accesses forms or display-status caches.
param([string]$SourceRoot,[string]$ConfigPath,[string]$Operation,[string[]]$Roles,[string]$ThreadId='',[object]$KnownInstances=$null)
$ErrorActionPreference='Stop'
if(-not (Test-Path Function:\Get-InstanceStatus)){. "$SourceRoot\Instances.ps1"}
$config=Read-ControllerConfig $ConfigPath
if($Operation -eq 'diagnostics'){
    . "$SourceRoot\Diagnostics.ps1"
    $report=Get-ControllerDiagnostics $config (Split-Path $SourceRoot -Parent)
    [pscustomobject]@{Report=$report;Text=(ConvertTo-ControllerDiagnosticText $report)}
    return
}
foreach($instance in $config.instances){
    if($Roles -and $instance.role -notin $Roles){continue}
    try{
        if($Operation -eq 'status'){
            $status=Get-InstanceStatus $config $instance
            [pscustomobject]@{Role=$instance.role;InstanceId=$instance.id;Home=$instance.home;Profile=$instance.profile;ConfiguredExecutable=$instance.executable;State=$status.State;Reason=$status.Reason;Process=$status.Process}
        }elseif($Operation -in @('open','task')){
            $quickIdentity=$false;$cached=Get-ObjectValue $KnownInstances $instance.role $null
            if($Operation -eq 'open' -and $cached -and $cached.State -eq 'Running' -and $cached.InstanceId -eq $instance.id -and $cached.Home -eq $instance.home -and $cached.Profile -eq $instance.profile -and (Get-ObjectValue $cached 'ConfiguredExecutable' '<missing>') -eq $instance.executable){
                $candidate=$cached.Process
                $quickIdentity=[CodexDual.Native]::IsKnownProcess($candidate.Id,[long]$candidate.Started,$candidate.Path,$candidate.Command,$instance.home,$instance.profile)
            }
            $process=if($quickIdentity){$candidate}else{Start-OrFindInstance $config $instance}
            $taskOutcome=''
            if($Operation -eq 'task'){
                . "$SourceRoot\CompletionNavigation.ps1"
                $taskOutcome=Request-InstanceTask $instance $process $ThreadId
            }
            [void](Request-NativeInstanceActivation $instance $process -QuickIdentity:$quickIdentity)
            Assert-ActivationIdentity $instance $process -QuickIdentity:$quickIdentity
            $windows=@([CodexDual.Native]::Windows($process.Id) | Where-Object {$_.Visible})
            for($retry=0;$windows.Count -eq 0 -and $retry -lt 30;$retry++){
                Start-Sleep -Milliseconds 100
                Assert-ActivationIdentity $instance $process -QuickIdentity:$quickIdentity
                $windows=@([CodexDual.Native]::Windows($process.Id) | Where-Object {$_.Visible})
            }
            if(-not $windows.Count){throw '已确认实例运行，但尚未显示主窗口。请从对应端的原生托盘恢复。'}
            [pscustomobject]@{Role=$instance.role;Process=$process;Windows=$windows;Error='';TaskOutcome=$taskOutcome;QuickIdentity=$quickIdentity}
        }else{throw 'Unknown controller operation.'}
    }catch{
        [pscustomobject]@{Role=$instance.role;State='Unknown';Reason='状态未知';Process=$null;Windows=@();Error=$_.Exception.Message}
    }
}
