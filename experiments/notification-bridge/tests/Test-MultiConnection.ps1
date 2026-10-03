$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1.'}
$experiment=Split-Path $PSScriptRoot -Parent
$repo=[IO.Path]::GetFullPath((Join-Path $experiment '..\..'))
$root=Join-Path $repo ('test-results\multi-connection-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$proxy=Join-Path $root 'BridgeProxy.exe'
& "$experiment\Build-Bridge.ps1" -Destination $proxy|Out-Null
$compiler=New-Object Microsoft.CSharp.CSharpCodeProvider
$parameters=New-Object CodeDom.Compiler.CompilerParameters
$parameters.GenerateExecutable=$true;$parameters.OutputAssembly=Join-Path $root 'Fixture.exe'
foreach($assembly in @('System.dll','System.Core.dll','System.Web.Extensions.dll')){[void]$parameters.ReferencedAssemblies.Add($assembly)}
try{$build=$compiler.CompileAssemblyFromFile($parameters,(Join-Path $PSScriptRoot 'TakeoverFixture.cs'));if($build.Errors.HasErrors){throw ($build.Errors|Out-String)}}finally{$compiler.Dispose()}
Add-Type -Path "$repo\src\QuestionBridgeClient.cs" -ReferencedAssemblies System.dll,System.Core.dll,System.Web.Extensions.dll
$taskHome=Join-Path $root 'home';[void][IO.Directory]::CreateDirectory($taskHome)
$basePipe='multi-fixture-'+[guid]::NewGuid().ToString('N');$instance='multi-fixture'
[IO.File]::WriteAllText((Join-Path $root 'bridge.config.json'),(@{realCli=$parameters.OutputAssembly;apiHome=$taskHome;pipeName=$basePipe;instanceId=$instance;takeoverQuestions=$true;multiConnection=$true}|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
$cases=New-Object Collections.ArrayList;$passed=0
function Check($condition,$message){if(-not $condition){throw "FAIL: $message"};$script:passed++;Write-Output "PASS: $message"}
function StartCase([string]$executable=$proxy) {
 $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=$executable;$start.Arguments='app-server';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$start.EnvironmentVariables['CODEX_HOME']=$taskHome
 $process=[Diagnostics.Process]::Start($start);$writer=New-Object IO.StreamWriter($process.StandardInput.BaseStream,(New-Object Text.UTF8Encoding($false)));$writer.AutoFlush=$true
 $case=@{Process=$process;Writer=$writer};[void]$cases.Add($case);return $case
}
function Send($case,$message){$case.Writer.WriteLine(($message|ConvertTo-Json -Depth 30 -Compress))}
function Read($case){$task=$case.Process.StandardOutput.ReadLineAsync();if(-not $task.Wait(5000)){throw 'Mock read timeout'};if($null -eq $task.Result){throw ('Mock EOF: '+$case.Process.StandardError.ReadToEnd())};return ($task.Result|ConvertFrom-Json)}
function AwaitReply($client){$deadline=[DateTime]::UtcNow.AddSeconds(8);do{$reply=$client.Take();if($reply){if($reply.Error){throw ('Client failed: '+$reply.Error)};return ($reply.Json|ConvertFrom-Json)};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline);throw 'Question client timeout'}
function Snapshot($client){if(-not $client.StartSnapshot()){throw 'Client busy'};return AwaitReply $client}
function Barrier($case){Send $case @{method='mock/barrier'};return Read $case}
function Question {return @{id=10;method='item/tool/requestUserInput';params=@{threadId='same-thread';turnId='same-turn';itemId='same-item';questions=@(@{id='q';header='synthetic';question='Choose B';options=@(@{label='A';description=''},@{label='B';description=''})})}}}
function Answer($client,$pending){$command=@{command='answer';requestId=$pending.requestId;connectionId=$pending.connectionId;requestToken=$pending.requestToken;threadId=$pending.threadId;turnId=$pending.turnId;answers=@{q=@{answers=@('B')}}};if(-not $client.StartAnswer(($command|ConvertTo-Json -Depth 30 -Compress),$pending.requestToken)){throw 'Client answer busy'};return AwaitReply $client}
$client=$null
$originalInputEncoding=[Console]::InputEncoding
try {
 # .NET Framework constructs Process.StandardInput from Console.InputEncoding.
 # Its default writer can emit a BOM even when our explicit writer is BOM-free;
 # the proxy's native fallback must receive the same JSON bytes as normal mode.
 [Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
 $first=StartCase;$second=StartCase
 $deadline=[DateTime]::UtcNow.AddSeconds(5)
 do{$records=@(Get-ChildItem (Join-Path $root 'connections') -Filter '*.json' -ErrorAction SilentlyContinue);if($records.Count -eq 2){break};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline)
 Check ($records.Count -eq 2) 'Concurrent proxy processes publish two independent endpoint records'
 $registrations=@($records|ForEach-Object {Get-Content $_.FullName -Raw|ConvertFrom-Json})
 foreach($record in $registrations){
  $process=[Diagnostics.Process]::GetProcessById($record.processId)
  try{Check ($record.schema -eq 1 -and $record.instanceId -ceq $instance -and $record.startedUtcTicks -eq $process.StartTime.ToUniversalTime().Ticks -and $record.pipeName -ceq ($basePipe+'-'+$record.processId+'-'+$record.connectionId)) 'Registration binds process start time, instance and exact endpoint name'}finally{$process.Dispose()}
 }
 $client=New-Object CodexDual.QuestionBridgeClient($basePipe,$proxy,$instance,(Join-Path $root 'DISABLED'))
 $snapshot=Snapshot $client
 Check ($snapshot.connections -eq 2 -and $snapshot.takeoverActive) 'Actual controller client discovers and renews both proxy connections'
 Check ($snapshot.confirmedConnections.Count -eq 2 -and $snapshot.confirmedConnections -ccontains $registrations[0].connectionId -and $snapshot.confirmedConnections -ccontains $registrations[1].connectionId) 'Snapshot identifies the connections that actually confirmed pending state'
 foreach($case in @($first,$second)){Send $case @{method='mock/emit';params=@{message=(Question)}};Check ((Barrier $case).method -eq 'mock/barrier') 'Each live connection suppresses its own native question'}
 $snapshot=Snapshot $client
 Check ($snapshot.pending.Count -eq 2 -and @($snapshot.pending.connectionId|Select-Object -Unique).Count -eq 2) 'Client merges identical RPC and thread identities without merging connection ownership'
 $firstRecord=$registrations|Where-Object processId -eq $first.Process.Id
 $firstPending=$snapshot.pending|Where-Object connectionId -eq $firstRecord.connectionId
 Check (Answer $client $firstPending).ok 'Controller client routes first answer to its exact connection'
 $received=Read $first
 Check ($received.params.message.id -eq 10 -and $received.params.message.result.answers.q.answers[0] -ceq 'B') 'Only first runtime receives first answer'
 Check ((Barrier $second).params.count -eq 0) 'Second runtime receives no cross-connection steer or answer'
 $snapshot=Snapshot $client
 Check ($snapshot.pending.Count -eq 1 -and $snapshot.pending[0].connectionId -ne $firstPending.connectionId) 'First answer does not clear second connection pending question'
 $firstFile=Join-Path (Join-Path $root 'connections') ($first.Process.Id.ToString()+'-'+$firstRecord.connectionId+'.json')
 $saved=[IO.File]::ReadAllText($firstFile)
 $first.Writer.Close();Check ($first.Process.WaitForExit(5000) -and $first.Process.ExitCode -eq 0) 'First owner exits cleanly while second remains live'
 Check (-not (Test-Path -LiteralPath $firstFile)) 'Normal disconnect removes only its own endpoint record'
 [IO.File]::WriteAllText($firstFile,$saved,(New-Object Text.UTF8Encoding($false)))
 $snapshot=Snapshot $client
 Check ($snapshot.connections -eq 1 -and $snapshot.pending.Count -eq 1) 'Actual client filters dead-owner crash residue using process identity'
 Check ($snapshot.confirmedConnections.Count -eq 1 -and $snapshot.confirmedConnections -cnotcontains $firstRecord.connectionId) 'A missing owner is never reported as having confirmed question resolution'
 Check (Answer $client $snapshot.pending[0]).ok 'Second owner remains independently answerable after first exit'
 Check ((Read $second).params.message.result.answers.q.answers[0] -ceq 'B') 'Second answer reaches only second runtime'
 $secondRecord=$registrations|Where-Object processId -eq $second.Process.Id
 $second.Writer.Close();Check ($second.Process.WaitForExit(5000) -and $second.Process.ExitCode -eq 0) 'Second owner exits cleanly'
 Check (-not (Test-Path -LiteralPath (Join-Path (Join-Path $root 'connections') ($second.Process.Id.ToString()+'-'+$secondRecord.connectionId+'.json')))) 'Second cleanup preserves unrelated stale record'
 Check (Test-Path -LiteralPath $firstFile) 'Cleanup never deletes another connection registration'
 $capacity=StartCase
 $deadline=[DateTime]::UtcNow.AddSeconds(5)
 do{$capacityRecord=@(Get-ChildItem (Join-Path $root 'connections') -Filter '*.json'|ForEach-Object {Get-Content $_.FullName -Raw|ConvertFrom-Json}|Where-Object processId -eq $capacity.Process.Id);if($capacityRecord.Count -eq 1){break};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline)
 Check ($capacityRecord.Count -eq 1) 'Capacity fixture publishes its live endpoint'
 # Reserve synthetic live identities to exercise the hard cap without spawning 32 CLI engines.
 1..31|ForEach-Object {
  $connection=[guid]::NewGuid().ToString('N');$pidValue=$capacity.Process.Id
  $record=@{schema=1;instanceId=$instance;processId=$pidValue;startedUtcTicks=$capacity.Process.StartTime.ToUniversalTime().Ticks;connectionId=$connection;pipeName=($basePipe+'-'+$pidValue+'-'+$connection)}
  [IO.File]::WriteAllText((Join-Path (Join-Path $root 'connections') ($pidValue.ToString()+'-'+$connection+'.json')),($record|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
 }
 $overflow=StartCase;Send $overflow @{method='mock/emit';params=@{message=(Question)}}
 Check ((Read $overflow).method -eq 'item/tool/requestUserInput') 'A 33rd live endpoint fails safely to native question delivery'
 Check ((Barrier $overflow).method -eq 'mock/barrier') 'Capacity fallback preserves native stdio protocol'
 $overflow.Writer.Close();Check ($overflow.Process.WaitForExit(5000) -and $overflow.Process.ExitCode -eq 0) 'Capacity fallback process still exits normally'
 Check ($overflow.Process.StandardError.ReadToEnd().Contains('registration unavailable')) 'Capacity rejection reports a bounded registration failure'
 $capacity.Writer.Close();Check ($capacity.Process.WaitForExit(5000)) 'Capacity owner exits normally'
 $reparseRoot=Join-Path $root 'reparse-case';$redirect=Join-Path $root 'registry-target'
 [void][IO.Directory]::CreateDirectory($reparseRoot);[void][IO.Directory]::CreateDirectory($redirect)
 Copy-Item -LiteralPath $proxy -Destination (Join-Path $reparseRoot 'BridgeProxy.exe')
 Copy-Item -LiteralPath (Join-Path $root 'bridge.config.json') -Destination (Join-Path $reparseRoot 'bridge.config.json')
 [void](New-Item -ItemType Junction -Path (Join-Path $reparseRoot 'connections') -Target $redirect)
 $reparse=StartCase (Join-Path $reparseRoot 'BridgeProxy.exe');Send $reparse @{method='mock/emit';params=@{message=(Question)}}
 Check ((Read $reparse).method -eq 'item/tool/requestUserInput') 'Reparse registry is rejected with native question fallback'
 Check (@(Get-ChildItem -LiteralPath $redirect -Force).Count -eq 0) 'Registration never writes through a reparse registry path'
 $reparse.Writer.Close();Check ($reparse.Process.WaitForExit(5000) -and $reparse.Process.ExitCode -eq 0) 'Reparse fallback remains a healthy native transport'
 [IO.File]::WriteAllText((Join-Path $root 'evidence.json'),(@{success=$true;checks=$passed;scope='two real proxy processes and actual controller client';staleRecordFiltered=$true;answerIsolation=$true}|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
 Write-Output "PASSED $passed multi-connection checks: $root"
}finally{
 if($client){$client.Dispose()}
 foreach($case in $cases){try{if(-not $case.Process.HasExited){$case.Writer.Close();if(-not $case.Process.WaitForExit(5000)){$case.Process.Kill();$case.Process.WaitForExit()}}}catch{};try{$case.Process.Dispose()}catch{}}
 [Console]::InputEncoding=$originalInputEncoding
}
