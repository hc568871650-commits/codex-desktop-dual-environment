param([Parameter(Mandatory=$true)][string]$ConfigPath,
      [Parameter(Mandatory=$true)][string]$StateDirectory,
      [Parameter(Mandatory=$true)][string]$Epoch,
      [Parameter(Mandatory=$true)][string]$RunId,
      [Parameter(Mandatory=$true)][int]$ParentProcessId,
      [Parameter(Mandatory=$true)][long]$ParentStarted)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Instances.ps1"
. "$PSScriptRoot\CompletionMonitor.ps1"
if($Epoch -notmatch '^[a-f0-9]{32}$' -or $RunId -notmatch '^[a-f0-9]{32}$'){throw 'Invalid worker identity.'}
$config=Read-ControllerConfig $ConfigPath
$root=Get-FullDirectory $StateDirectory;Assert-NoReparsePoint $root
[void][IO.Directory]::CreateDirectory($root)
$inbox=Join-Path $root 'inbox';[void][IO.Directory]::CreateDirectory($inbox);Assert-NoReparsePoint $inbox
$stop=Join-Path $root ('stop-'+$RunId+'.request')
$statusPath=Join-Path $root 'worker-status.local.json'
$monitor=$null;$mutex=$null;$held=$false
function Write-WorkerStatus([string]$State,[int]$WarningCount=0){
    Write-AtomicText $statusPath (@{schema=1;runId=$RunId;state=$State;utc=[DateTime]::UtcNow.ToString('o');warnings=$WarningCount}|ConvertTo-Json -Compress)
}
try {
    $mutex=New-Object Threading.Mutex($false,('Local\CodexDual.Notifications.'+(Get-ControllerStartupName $ConfigPath)))
    try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not $held){exit 0}
    $monitor=New-CompletionMonitor $config (Join-Path $root ('monitor-'+$Epoch+'.local.json'))
    Write-WorkerStatus 'running'
    $ticks=0
    while(-not (Test-Path -LiteralPath $stop)){
        try{$parent=[Diagnostics.Process]::GetProcessById($ParentProcessId);try{if($parent.StartTime.ToUniversalTime().Ticks -ne $ParentStarted){break}}finally{$parent.Dispose()}}catch{break}
        $latest=@{}
        foreach($completion in @(Read-MonitorCompletions $monitor)){$latest[$completion.InstanceId]=$completion}
        foreach($completion in $latest.Values){
            $path=Join-Path $inbox ($completion.InstanceId+'-'+[Guid]::NewGuid().ToString('N')+'.local.json');Assert-NoReparsePoint $path
            Write-AtomicText $path (@{schema=1;epoch=$Epoch;eventId=[Guid]::NewGuid().ToString('N');instanceId=$completion.InstanceId;threadId=$completion.ThreadId;turnId=$completion.TurnId;utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress)
        }
        foreach($old in @(Get-ChildItem -LiteralPath $inbox -Filter '*.local.json' -File|Sort-Object LastWriteTimeUtc -Descending|Select-Object -Skip 128)){Assert-NoReparsePoint $old.FullName;Remove-Item -LiteralPath $old.FullName -Force}
        $ticks++;if($ticks -ge 10){Write-WorkerStatus 'running' ([int]$monitor.Warnings.Count);$ticks=0}
        Start-Sleep -Milliseconds 1000
    }
    Write-WorkerStatus 'stopped' ([int]$monitor.Warnings.Count)
}catch{if($held){try{Write-WorkerStatus 'failed'}catch{}};Write-Error -ErrorRecord $_ -ErrorAction Continue;exit 1}
finally{
    if($monitor){Close-CompletionMonitor $monitor}
    if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
    if(Test-Path -LiteralPath $stop){Remove-Item -LiteralPath $stop -Force}
}
