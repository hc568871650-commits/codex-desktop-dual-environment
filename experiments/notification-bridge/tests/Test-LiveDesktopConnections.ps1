param([Parameter(Mandatory=$true)][string]$TrialDirectory,[int]$MinimumConnections=1)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1.'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $PSScriptRoot '../Trial.Common.ps1')
$m=Read-BridgeTrial $TrialDirectory
Add-Type -Path (Join-Path $repo 'src/QuestionBridgeClient.cs') -ReferencedAssemblies System,System.Core,System.Web.Extensions
$cfg=Get-Content (Join-Path $m.root 'bridge.config.json') -Raw|ConvertFrom-Json
$client=New-Object CodexDual.QuestionBridgeClient($cfg.pipeName,(Join-Path $m.root 'BridgeProxy.exe'),$cfg.instanceId,(Join-Path $m.root 'DISABLED'))
try{
    [void]$client.StartSnapshot($true);$deadline=[DateTime]::UtcNow.AddSeconds(5)
    do{$reply=$client.Take();if($reply){break};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $deadline)
    if(-not $reply -or $reply.Error){throw 'Snapshot unavailable'}
    $v=$reply.Json|ConvertFrom-Json
    $regs=@(Get-ChildItem (Join-Path $m.root 'connections') -Filter '*.json'|ForEach-Object {Get-Content $_.FullName -Raw|ConvertFrom-Json})
    $desktop=(Get-Content (Join-Path $m.root 'desktop-process.json') -Raw|ConvertFrom-Json).pid
    $parents=@($regs|ForEach-Object {Get-CimInstance Win32_Process -Filter ('ProcessId='+$_.processId)})
    $e=@{desktopPid=$desktop;connections=$v.connections;takeoverActive=$v.takeoverActive;unavailableConnections=$v.unavailableConnections;allOwnedByDesktop=(@($parents|Where-Object {$_.ParentProcessId -ne $desktop}).Count -eq 0);pendingCount=@($v.pending).Count;utc=[DateTime]::UtcNow.ToString('o')}
    Write-TrialJson (Join-Path $m.root 'desktop-multi-validation.json') $e
    $e|ConvertTo-Json
    if($e.connections -lt $MinimumConnections -or -not $e.allOwnedByDesktop -or -not $e.takeoverActive){throw 'Desktop connection validation failed'}
}finally{$client.Dispose()}
