param([Parameter(Mandatory=$true)][string]$TrialDirectory)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Trial.Common.ps1')
$m=Read-BridgeTrial $TrialDirectory
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TrialPipeIdentity {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint pid);
}
'@
$passed=0;$evidence=@()
function Check($condition,[string]$name){if(-not $condition){throw ('FAIL: '+$name)};$script:passed++;Write-Output ('PASS: '+$name)}
function VerifiedRoot {
    $file=Join-Path $m.root 'desktop-process.json'
    if(-not (Test-Path -LiteralPath $file)){return $null}
    $record=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json
    $process=Get-Process -Id $record.pid -ErrorAction SilentlyContinue
    if(-not $process){return $null}
    if($process.StartTime.ToUniversalTime().ToString('o') -ne $record.startedUtc -or $process.Path -ne $m.desktopExe -or $record.profile -ne $m.profile -or $record.apiHome -ne $m.apiHome){throw 'Trial process identity changed; no cleanup performed.'}
    $native=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id)
    $pattern='--user-data-dir=(?:"'+[regex]::Escape($m.profile)+'"|'+[regex]::Escape($m.profile)+'(?:\s|$))'
    if($native.CommandLine -notmatch $pattern){throw 'Trial process profile could not be verified.'}
    return $process
}
function WaitRoot {
    $limit=[DateTime]::UtcNow.AddSeconds(15)
    do{$process=VerifiedRoot;if($process){return $process};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $limit)
    throw 'No verified isolated desktop was launched.'
}
function Descendants([int]$RootId) {
    $all=@(Get-CimInstance Win32_Process);$ids=New-Object 'Collections.Generic.HashSet[int]';[void]$ids.Add($RootId)
    do{$added=$false;foreach($item in $all){if($ids.Contains([int]$item.ParentProcessId) -and $ids.Add([int]$item.ProcessId)){$added=$true}}}while($added)
    return @($all|Where-Object {$ids.Contains([int]$_.ProcessId)})
}
function StopOwnedTrial {
    $rootProcess=VerifiedRoot;if(-not $rootProcess){return}
    $owned=@(Descendants $rootProcess.Id)
    [void]$rootProcess.CloseMainWindow()
    [void]$rootProcess.WaitForExit(1200)
    # Only this freshly-created, identity-checked trial tree can be cleaned up.
    foreach($item in @($owned|Sort-Object CreationDate -Descending)){
        $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$item.ProcessId)
        if($current -and $current.CreationDate -eq $item.CreationDate -and $current.ExecutablePath -eq $item.ExecutablePath){
            $ownedProcess=Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
            if($ownedProcess){try{$ownedProcess.Kill();[void]$ownedProcess.WaitForExit(3000)}finally{$ownedProcess.Dispose()}}
        }
    }
    $rootProcess.Dispose()
}
try{
    if(-not (VerifiedRoot)){
        & (Join-Path $m.root 'Enable-BridgeTrial.ps1')|Out-Null
        & (Join-Path $m.root 'Start-BridgeTrial.ps1')|Out-Null
    }
    $rootProcess=WaitRoot
    $cfg=Get-Content (Join-Path $m.root 'bridge.config.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $pipe=New-Object IO.Pipes.NamedPipeClientStream('.',$cfg.pipeName,[IO.Pipes.PipeDirection]::InOut)
    try{
        $pipe.Connect(12000);$writer=New-Object IO.StreamWriter($pipe);$writer.AutoFlush=$true;$reader=New-Object IO.StreamReader($pipe)
        $writer.WriteLine('{"command":"snapshot"}');$read=$reader.ReadLineAsync();if(-not $read.Wait(3000)){throw 'Trial desktop pipe timeout'}
        $snapshot=$read.Result|ConvertFrom-Json
        Check ($snapshot.ok -and $snapshot.instanceId -eq $cfg.instanceId) 'Actual desktop launched the bound bridge pipe'
        [uint32]$pipeServerId=0
        if(-not [TrialPipeIdentity]::GetNamedPipeServerProcessId($pipe.SafePipeHandle.DangerousGetHandle(),[ref]$pipeServerId)){throw 'Cannot verify the pipe server process'}
    }finally{$pipe.Dispose()}
    $tree=@(Descendants $rootProcess.Id)
    # Desktop also invokes the configured CLI for short-lived version/probe calls.
    # Bind ownership to the kernel-reported pipe server, not every transient proxy.
    $proxy=@($tree|Where-Object {$_.ProcessId -eq $pipeServerId -and $_.ExecutablePath -eq (Join-Path $m.root 'BridgeProxy.exe')})
    # Startup can replace the first app-server. Re-handshake rather than accepting
    # an old pipe PID or weakening the verified desktop ancestry requirement.
    $identityDeadline=[DateTime]::UtcNow.AddSeconds(12)
    while($proxy.Count -ne 1 -and [DateTime]::UtcNow -lt $identityDeadline){
        Start-Sleep -Milliseconds 250
        $retryPipe=New-Object IO.Pipes.NamedPipeClientStream('.',$cfg.pipeName,[IO.Pipes.PipeDirection]::InOut)
        try{
            $retryPipe.Connect(2000)
            $retryWriter=New-Object IO.StreamWriter($retryPipe);$retryWriter.AutoFlush=$true
            $retryReader=New-Object IO.StreamReader($retryPipe);$retryWriter.WriteLine('{"command":"snapshot"}')
            $retryRead=$retryReader.ReadLineAsync();if(-not $retryRead.Wait(2000)){throw 'Retry handshake timed out'}
            $retrySnapshot=$retryRead.Result|ConvertFrom-Json
            if(-not $retrySnapshot.ok -or $retrySnapshot.instanceId -ne $cfg.instanceId){throw 'Retry handshake identity differs'}
            if(-not [TrialPipeIdentity]::GetNamedPipeServerProcessId($retryPipe.SafePipeHandle.DangerousGetHandle(),[ref]$pipeServerId)){throw 'Cannot verify replacement pipe process'}
        }finally{$retryPipe.Dispose()}
        $tree=@(Descendants $rootProcess.Id)
        $proxy=@($tree|Where-Object {$_.ProcessId -eq $pipeServerId -and $_.ExecutablePath -eq (Join-Path $m.root 'BridgeProxy.exe')})
    }
    Write-TrialJson (Join-Path $m.root 'desktop-identity-probe.json') @{desktopPid=$rootProcess.Id;pipeServerPid=$pipeServerId;descendants=@($tree|Where-Object {$_.Name -in @('BridgeProxy.exe','codex.exe')}|Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine)}
    Check ($proxy.Count -eq 1 -and $proxy[0].ParentProcessId -eq $rootProcess.Id -and $proxy[0].CommandLine -match '(?:^|\s)app-server(?:\s|$)') 'Pipe-owning app-server proxy belongs to the isolated desktop'
    Check (@($tree|Where-Object {$_.ParentProcessId -eq $proxy[0].ProcessId -and $_.ExecutablePath -eq $m.realCli}).Count -eq 1) 'Proxy owns the expected bundled real CLI child'
    $evidence+=@{phase='bridge';desktopPid=$rootProcess.Id;proxyPid=$proxy[0].ProcessId;pipeMatched=$true}
    & (Join-Path $m.root 'Rollback-ApiBridge.ps1')|Out-Null
    $still=VerifiedRoot
    Check ($still -and $still.Id -eq $rootProcess.Id) 'Rollback does not terminate the running trial desktop'
    StopOwnedTrial
    & (Join-Path $m.root 'Start-BridgeTrial.ps1') -WithoutBridge|Out-Null
    $fallback=WaitRoot
    $limit=[DateTime]::UtcNow.AddSeconds(15)
    do{$tree=@(Descendants $fallback.Id);$cli=@($tree|Where-Object {$_.Name -eq 'codex.exe'});if($cli.Count){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $limit)
    Check ($cli.Count -gt 0) 'Bypass launch starts the native CLI'
    Check (@($tree|Where-Object {$_.ExecutablePath -eq (Join-Path $m.root 'BridgeProxy.exe')}).Count -eq 0) 'Bypass launch has no proxy in its process tree'
    $evidence+=@{phase='fallback';desktopPid=$fallback.Id;proxyCount=0;nativeCliCount=$cli.Count}
}finally{StopOwnedTrial}
Check (Test-Path -LiteralPath (Join-Path $m.root 'DISABLED')) 'Delivered trial remains rolled back'
Write-TrialJson (Join-Path $m.root 'desktop-validation.json') @{passed=$passed;scope='desktop-launch-and-fallback-only';modelRequests=0;events=$evidence;utc=[DateTime]::UtcNow.ToString('o')}
Write-Output ('PASSED: '+$passed+' isolated desktop checks. Trial windows closed; no model tasks sent.')
