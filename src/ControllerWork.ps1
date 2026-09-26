# Runs in a dedicated runspace; never accesses forms or display-status caches.
param([string]$SourceRoot,[string]$ConfigPath,[string]$Operation,[string[]]$Roles,[string]$ThreadId='')
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
            [pscustomobject]@{Role=$instance.role;State=$status.State;Reason=$status.Reason;Process=$status.Process}
        }elseif($Operation -in @('open','task')){
            $process=Start-OrFindInstance $config $instance
            $taskOutcome=''
            if($Operation -eq 'task'){
                . "$SourceRoot\CompletionNavigation.ps1"
                $taskOutcome=Request-InstanceTask $instance $process $ThreadId
            }
            [void](Request-NativeInstanceActivation $instance $process)
            $windows=@(Get-InstanceWindows $instance $process | Where-Object {$_.Visible})
            for($retry=0;$windows.Count -eq 0 -and $retry -lt 30;$retry++){
                Start-Sleep -Milliseconds 100
                $windows=@(Get-InstanceWindows $instance $process | Where-Object {$_.Visible})
            }
            if(-not $windows.Count){throw '已确认实例运行，但尚未显示主窗口。请从对应端的原生托盘恢复。'}
            [pscustomobject]@{Role=$instance.role;Process=$process;Windows=$windows;Error='';TaskOutcome=$taskOutcome}
        }else{throw 'Unknown controller operation.'}
    }catch{
        [pscustomobject]@{Role=$instance.role;State='Unknown';Reason='状态未知';Process=$null;Windows=@();Error=$_.Exception.Message}
    }
}
