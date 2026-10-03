$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1.'}
$originalEncoding=[Console]::InputEncoding
[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
$experiment=Split-Path $PSScriptRoot -Parent
$root=Join-Path ([IO.Path]::GetFullPath("$experiment\..\..\test-results")) ('takeover-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$passed=0;$cases=New-Object Collections.ArrayList
function Check($value,$message){if(-not $value){throw "FAIL: $message"};$script:passed++;Write-Host "PASS: $message"}
function Read($reader){$task=$reader.ReadLineAsync();if(-not $task.Wait(7000)){throw 'Fixture read timeout'};if($null -eq $task.Result){throw 'Fixture EOF'};return ($task.Result|ConvertFrom-Json)}
function Send($case,$message){$case.Writer.WriteLine(($message|ConvertTo-Json -Depth 40 -Compress))}
function Emit($case,$message){Send $case @{method='mock/emit';params=@{message=$message}}}
function Barrier($case){Send $case @{method='mock/barrier'};return Read $case.Process.StandardOutput}
function Pipe($case,$message){
 $pipe=New-Object IO.Pipes.NamedPipeClientStream('.',$case.Pipe,[IO.Pipes.PipeDirection]::InOut);$pipe.Connect(3000)
 try{$writer=New-Object IO.StreamWriter($pipe);$writer.AutoFlush=$true;$reader=New-Object IO.StreamReader($pipe);$writer.WriteLine(($message|ConvertTo-Json -Depth 40 -Compress));return Read $reader}finally{$pipe.Dispose()}
}
function StartCase($name,[bool]$enabled=$true,[bool]$wrongHome=$false,[bool]$disabled=$false){
 $directory=Join-Path $root $name;[void][IO.Directory]::CreateDirectory($directory)
 $taskHome=Join-Path $directory 'api-home';[void][IO.Directory]::CreateDirectory($taskHome)
 $proxy=Join-Path $directory 'BridgeProxy.exe';Copy-Item (Join-Path $root 'BridgeProxy.exe') $proxy
 $pipe='takeover-'+[guid]::NewGuid().ToString('N')
 [IO.File]::WriteAllText((Join-Path $directory 'bridge.config.json'),(@{realCli=(Join-Path $root 'Fixture.exe');apiHome=$taskHome;instanceId=$name;pipeName=$pipe;takeoverQuestions=$enabled}|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
 if($disabled){[IO.File]::WriteAllText((Join-Path $directory 'DISABLED'),'')}
 $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=$proxy;$start.Arguments='app-server';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
 $start.EnvironmentVariables['CODEX_HOME']=if($wrongHome){$root}else{$taskHome}
 $process=[Diagnostics.Process]::Start($start)
 $writer=New-Object IO.StreamWriter($process.StandardInput.BaseStream,(New-Object Text.UTF8Encoding($false)));$writer.AutoFlush=$true
 $case=@{Process=$process;Writer=$writer;Pipe=$pipe;Directory=$directory};[void]$cases.Add($case);return $case
}
function Snapshot($case,[bool]$ready=$true){return Pipe $case @{command='snapshot';takeoverReady=$ready}}
function IdentityCommand($pending,$name){return @{command=$name;connectionId=$pending.connectionId;requestToken=$pending.requestToken;requestId=$pending.requestId;threadId=$pending.threadId;turnId=$pending.turnId}}
function Traditional($id,$item='classic',$turn='turn-a') {return @{id=$id;method='item/tool/requestUserInput';params=@{threadId='api-thread';turnId=$turn;itemId=$item;isBlocking=$true;questions=@(@{id='q';header='fixture';question='synthetic';options=@(@{label='A';description='fixture'})})}}}
function Async($item='async-item',$turn='turn-a',$thread='api-thread',$method='item/started'){return @{method=$method;params=@{threadId=$thread;turnId=$turn;item=@{type='agentMessage';id=$item;text='retain this message';phase='commentary';delivery='async';questions=@(@{title='synthetic async';options=@('A','B')})}}}}
function AddAsync($case,$item,$turn='turn-a'){Emit $case (Async $item $turn);$projected=Read $case.Process.StandardOutput;Check ($null -eq $projected.params.item.questions -and $projected.params.item.text -ceq 'retain this message') 'Async projection removes only questions';return (Snapshot $case).pending|Where-Object {$_.itemId -eq $item}}
function AnswerCommand($p){$command=IdentityCommand $p 'answer';$command.answers=@{};foreach($q in $p.questions){$command.answers[$q.id]=@{answers=@('A')}};return $command}
try{
 & (Join-Path $experiment 'Build-Bridge.ps1') -Destination (Join-Path $root 'BridgeProxy.exe')|Out-Null
 $compiler=New-Object Microsoft.CSharp.CSharpCodeProvider;$options=New-Object CodeDom.Compiler.CompilerParameters;$options.GenerateExecutable=$true;$options.OutputAssembly=Join-Path $root 'Fixture.exe'
 foreach($assembly in @('System.dll','System.Core.dll','System.Web.Extensions.dll')){[void]$options.ReferencedAssemblies.Add($assembly)}
 try{$built=$compiler.CompileAssemblyFromFile($options,(Join-Path $PSScriptRoot 'TakeoverFixture.cs'));if($built.Errors.HasErrors){throw ($built.Errors|Out-String)}}finally{$compiler.Dispose()}
 $case=StartCase 'exclusive'
 [void](Snapshot $case $false)
 Emit $case (Traditional 10 'no-ready');$native=Read $case.Process.StandardOutput
 Check ($native.id -eq 10 -and (Snapshot $case $false).pending.Count -eq 0) 'No-ready takeover traditional request reaches native without external copy'
 Emit $case (Async 'no-ready-async');Check ((Read $case.Process.StandardOutput).params.item.questions.Count -eq 1) 'No-ready async projection is untouched'
 [void](Snapshot $case)
 Emit $case (Async 'no-ready-async' 'turn-a' 'api-thread' 'item/completed');Check ((Read $case.Process.StandardOutput).params.item.questions.Count -eq 1) 'Native started then ready completed never steals existing async entry'
 Emit $case (Traditional 10 'no-ready');Check ((Read $case.Process.StandardOutput).id -eq 10) 'Native classic then ready replay never steals existing entry'
 Check ((Snapshot $case).pending.Count -eq 0) 'Late client activation does not create duplicate external questions'
 Emit $case @{id=99;method='item/tool/requestOptionPicker';params=@{threadId='api-thread';turnId='turn-a'}}
 Check ((Read $case.Process.StandardOutput).method -eq 'item/tool/requestOptionPicker') 'Unknown server request is transparent with live takeover'
 foreach($fault in @('empty','duplicate-id','missing-question','bad-option','bad-flag','bad-blocking','rich-field')){
  $bad=Traditional 98 ('bad-'+$fault)
  switch($fault){
   'empty' {$bad.params.questions=@()}
   'duplicate-id' {$bad.params.questions+=@($bad.params.questions[0].Clone())}
   'missing-question' {$bad.params.questions[0].Remove('question')}
   'bad-option' {$bad.params.questions[0].options=@(@{label='A';description=7})}
   'bad-flag' {$bad.params.questions[0].isSecret='false'}
   'bad-blocking' {$bad.params.isBlocking='true'}
   'rich-field' {$bad.params.questions[0].image=@{url='fixture'}}
  }
  Emit $case $bad;Check ((Read $case.Process.StandardOutput).id -eq 98) ("Unrenderable classic $fault stays native")
  Check (@((Snapshot $case).pending|Where-Object {$_.requestId -eq 98}).Count -eq 0) ("Unrenderable classic $fault never becomes pending")
 }
 $malformed=Async 'malformed';$malformed.params.item.questions[0].options=@(@{label='not-a-string'})
 Emit $case $malformed;Check ((Read $case.Process.StandardOutput).params.item.questions[0].options[0].label -ceq 'not-a-string') 'Unknown async question shape falls back to native'
 $ordinary=Async 'ordinary';$ordinary.params.item.questions=$null
 Emit $case $ordinary;Check ((Read $case.Process.StandardOutput).params.item.text -ceq 'retain this message') 'Ordinary assistant message remains intact'
 Emit $case (Traditional 11);Check ((Barrier $case).method -eq 'mock/barrier') 'Ready traditional request is hidden before native output'
 $p=(Snapshot $case).pending|Where-Object {$_.requestId -eq 11};Check ($p.delivery -eq 'exclusive') 'Snapshot identifies exclusive ownership'
 $command=AnswerCommand $p;Check (Pipe $case $command).ok 'Traditional answer succeeds'
 $received=Read $case.Process.StandardOutput;Check ($received.params.message.id -eq 11) 'Traditional answer keeps original RPC ID'
 Check ((Barrier $case).method -eq 'mock/barrier') 'Hidden traditional answer sends no unknown resolved event'
 Check ((Pipe $case $command).error -eq 'stale') 'Duplicate traditional answer rejected'
 Emit $case (Traditional 11);Check ((Barrier $case).method -eq 'mock/barrier') 'Answered identical traditional request replay never recreates native question'
 Check (@((Snapshot $case).pending|Where-Object {$_.requestId -eq 11}).Count -eq 0) 'Answered identical traditional replay never recreates external question'
 $p=AddAsync $case 'success';Check ($p.kind -eq 'async' -and $p.questions[0].id -ceq '0' -and $p.questions[0].isOther -and $p.questions[0].options[0].label -ceq 'A') 'Async questions normalized for existing editor'
 $empty=AnswerCommand $p;$empty.answers['0'].answers=@(' ');Check ((Pipe $case $empty).error -eq 'invalid') 'Empty async answer never reaches steer'
 $command=AnswerCommand $p;Check (Pipe $case $command).ok 'Async answer waits for successful steer response'
 $steer=Read $case.Process.StandardOutput;$rpc=$steer.params.message
 Check ($rpc.method -eq 'turn/steer' -and $rpc.params.expectedTurnId -ceq 'turn-a' -and $rpc.id -like 'codex-bridge-steer:*') 'Async submission has internal unique ID and turn precondition'
 $text=$rpc.params.input[0].text;$reply=($text -replace '^<send_user_message_question_reply>\n','' -replace '\n</send_user_message_question_reply>$','')|ConvertFrom-Json
 Check ($reply[0].questionItemId -ceq '["request_user_input_async","success",0]' -and $reply[0].answer -ceq 'A') 'Async wrapper matches native question ID and answer encoding'
 Check ((Pipe $case $command).error -eq 'stale') 'Duplicate async success is stale'
 Emit $case (Async 'success' 'turn-a' 'api-thread' 'item/completed');Check ($null -eq (Read $case.Process.StandardOutput).params.item.questions) 'Answered item/completed replay stays scrubbed'
 Check (@((Snapshot $case).pending|Where-Object {$_.itemId -eq 'success'}).Count -eq 0) 'Answered replay creates no new external pending'
 $history=@{thread=@{id='api-thread';turns=@(@{id='turn-a';items=@((Async 'success').params.item,(Async 'unknown').params.item)})}}
 Send $case @{id=80;method='thread/read';params=@{threadId='api-thread';fixtureResult=$history}};$result=Read $case.Process.StandardOutput
 Check ($null -eq $result.result.thread.turns[0].items[0].questions -and $result.result.thread.turns[0].items[1].questions.Count -eq 1) 'History scrubs only exact answered identity and keeps unknown question'
 $foreign=@{thread=@{id='other-thread';turns=@(@{id='turn-a';items=@((Async 'success').params.item)})}}
 Send $case @{id=81;method='thread/read';params=@{threadId='other-thread';fixtureResult=$foreign}}
 Check ((Read $case.Process.StandardOutput).result.thread.turns[0].items[0].questions.Count -eq 1) 'Same item ID in another thread is not hidden'
 $p=AddAsync $case 'release';$command=IdentityCommand $p 'release';$wrong=$command.Clone();$wrong.threadId='wrong'
 Check ((Pipe $case $wrong).error -eq 'stale') 'Release cannot target another thread'
 Check (Pipe $case $command).ok 'Explicit return-native release accepted'
 Check ((Read $case.Process.StandardOutput).params.item.questions.Count -eq 1) 'Release restores original native question'
 Emit $case (Async 'release' 'turn-a' 'api-thread' 'item/completed');Check ((Read $case.Process.StandardOutput).params.item.questions.Count -eq 1) 'Released identity is never recaptured'
 Check (@((Snapshot $case).pending|Where-Object {$_.itemId -eq 'release'}).Count -eq 0) 'Release removes external entry'
 Send $case @{method='mock/mode';params=@{mode='error'}};[void](Read $case.Process.StandardOutput)
 $p=AddAsync $case 'error';$command=AnswerCommand $p
 Check ((Pipe $case $command).error -eq 'steer-rejected') 'expectedTurnId error is reported without success';[void](Read $case.Process.StandardOutput)
 Check (@((Snapshot $case).pending|Where-Object {$_.itemId -eq 'error'}).Count -eq 1) 'Rejected steer preserves pending and draft identity'
 Send $case @{method='mock/mode';params=@{mode='success'}};[void](Read $case.Process.StandardOutput)
 Check (Pipe $case $command).ok 'Known rejection can be retried';[void](Read $case.Process.StandardOutput)
 Send $case @{method='mock/mode';params=@{mode='timeout'}};[void](Read $case.Process.StandardOutput)
 $p=AddAsync $case 'uncertain';$command=AnswerCommand $p
 $answerPipe=New-Object IO.Pipes.NamedPipeClientStream('.',$case.Pipe,[IO.Pipes.PipeDirection]::InOut);$answerPipe.Connect(3000)
 $answerWriter=New-Object IO.StreamWriter($answerPipe);$answerWriter.AutoFlush=$true;$answerReader=New-Object IO.StreamReader($answerPipe)
 $answerWriter.WriteLine(($command|ConvertTo-Json -Depth 40 -Compress));[void](Read $case.Process.StandardOutput)
 $during=[Diagnostics.Stopwatch]::StartNew();$inFlight=(Snapshot $case).pending|Where-Object {$_.itemId -eq 'uncertain'}
 Check ($inFlight.outcomeUnknown -and $during.ElapsedMilliseconds -lt 1000) 'In-flight wait releases gate so heartbeat and snapshot remain responsive'
 Check ((Pipe $case $command).error -eq 'outcome-unknown') 'Concurrent competing answer cannot emit another steer'
 try{Check ((Read $answerReader).error -eq 'outcome-unknown') 'Steer timeout is ambiguous'}finally{$answerPipe.Dispose()}
 Check ((Pipe $case $command).error -eq 'outcome-unknown') 'Unknown submission cannot resend'
 Check ((Pipe $case (IdentityCommand $p 'release')).error -eq 'outcome-unknown') 'Unknown submission cannot create a second native answer entry'
 $before=Barrier $case
 [void](Snapshot $case $false)
 Check ((Barrier $case).method -eq 'mock/barrier') 'Lease revocation does not replay an ambiguous in-flight steer'
 Send $case @{method='mock/late'};Check ((Read $case.Process.StandardOutput).method -eq 'mock/late-done') 'Late internal success is consumed without leaking RPC response'
 Check (@((Snapshot $case).pending|Where-Object {$_.itemId -eq 'uncertain'}).Count -eq 0) 'Late success resolves ambiguous external state'
 Check ((Barrier $case).params.count -eq $before.params.count) 'Timeout retry and release emitted no second steer'
 Send $case @{method='mock/mode';params=@{mode='wrong-success'}};[void](Read $case.Process.StandardOutput)
 $p=AddAsync $case 'wrong-success';$command=AnswerCommand $p
 Check ((Pipe $case $command).error -eq 'outcome-unknown') 'Wrong-turn success envelope does not count as known rejection';[void](Read $case.Process.StandardOutput)
 Check ((Pipe $case $command).error -eq 'outcome-unknown') 'Wrong-turn success cannot be retried and double submitted'
 Send $case @{method='mock/late'};[void](Read $case.Process.StandardOutput)
 Send $case @{method='mock/mode';params=@{mode='success'}};[void](Read $case.Process.StandardOutput)
 [void](Snapshot $case);$completed=AddAsync $case 'completed';Emit $case @{method='turn/completed';params=@{threadId='api-thread';turn=@{id='turn-a'}}};[void](Read $case.Process.StandardOutput)
 Check (@((Snapshot $case).pending|Where-Object {$_.itemId -eq 'completed'}).Count -eq 0) 'Completed turn clears pending without submitting'
 Emit $case (Async 'after-completed' 'turn-a');Check ((Read $case.Process.StandardOutput).params.item.questions.Count -eq 1) 'Late question from completed turn is not newly captured'
 # Use a new turn for the watchdog fixture after completion.
 [void](Snapshot $case)
 Emit $case (Traditional 20 'expire' 'turn-b');Check ((Barrier $case).method -eq 'mock/barrier') 'Lease expiry fixture initially hidden'
 $watch=[Diagnostics.Stopwatch]::StartNew();$restored=Read $case.Process.StandardOutput
 Check ($restored.id -eq 20 -and $watch.ElapsedMilliseconds -lt 6500) 'Watchdog restores hidden native request without any client command'
 Check (@((Snapshot $case $false).pending|Where-Object {$_.requestId -eq 20}).Count -eq 0) 'Expired lease clears exclusive pending'
 [void](Snapshot $case);$p=AddAsync $case 'pause' 'turn-b';[void](Snapshot $case $false)
 Check ((Read $case.Process.StandardOutput).params.item.questions.Count -eq 1) 'takeoverReady false immediately restores native async question'
 Send $case @{id=82;method='thread/read';params=@{threadId='api-thread';fixtureResult=$history}}
 Check ((Read $case.Process.StandardOutput).result.thread.turns[0].items[0].questions.Count -eq 1) 'No active lease leaves historical projection untouched'
 [void](Snapshot $case);Emit $case (Traditional 21 'disabled' 'turn-b');[void](Barrier $case)
 $rollbackPipe=New-Object IO.Pipes.NamedPipeClientStream('.',$case.Pipe,[IO.Pipes.PipeDirection]::InOut);$rollbackPipe.Connect(3000)
 $rollbackWriter=New-Object IO.StreamWriter($rollbackPipe);$rollbackWriter.AutoFlush=$true;$rollbackReader=New-Object IO.StreamReader($rollbackPipe)
 [IO.File]::WriteAllText((Join-Path $case.Directory 'DISABLED'),'')
 Check ((Read $case.Process.StandardOutput).id -eq 21) 'Live DISABLED watchdog returns hidden traditional question'
 try{$rollbackWriter.WriteLine('{"command":"snapshot","takeoverReady":false}');Check ((Read $rollbackReader).pending.Count -eq 0) 'Rollback clears pending while child continues'}finally{$rollbackPipe.Dispose()}
 Emit $case (Async 'post-disabled');Check ((Read $case.Process.StandardOutput).params.item.questions.Count -eq 1) 'Disabled bridge continues native transparent transport'
 $mirror=StartCase 'default-mirror' $false;[void](Snapshot $mirror)
 Emit $mirror (Traditional 30);Check ((Read $mirror.Process.StandardOutput).id -eq 30) 'Default mirror preserves old native flow even ready client'
 $disconnect=StartCase 'answer-client-disconnect';[void](Snapshot $disconnect)
 $disconnectPending=AddAsync $disconnect 'disconnect-question'
 Send $disconnect @{method='mock/mode';params=@{mode='timeout'}};[void](Read $disconnect.Process.StandardOutput)
 $brokenPipe=New-Object IO.Pipes.NamedPipeClientStream('.',$disconnect.Pipe,[IO.Pipes.PipeDirection]::InOut);$brokenPipe.Connect(3000)
 $brokenWriter=New-Object IO.StreamWriter($brokenPipe);$brokenWriter.AutoFlush=$true
 $brokenWriter.WriteLine(((AnswerCommand $disconnectPending)|ConvertTo-Json -Depth 40 -Compress))
 Check ((Read $disconnect.Process.StandardOutput).method -eq 'mock/steer') 'Answer reaches runtime before client disconnect'
 $brokenPipe.Dispose()
 Start-Sleep -Milliseconds 1600
 Check (-not $disconnect.Process.HasExited) 'Broken answer pipe cleanup cannot terminate bridge process'
 Check ((Barrier $disconnect).method -eq 'mock/barrier') 'Stdio remains usable after disconnected answer client'
 Check (Snapshot $disconnect).ok 'New question client can reconnect after broken pipe cleanup'
 $large=Traditional 35 'large-snapshot';$large.params.questions[0].question=('x'*65536)
 Emit $disconnect $large;[void](Barrier $disconnect)
 $partialPipe=New-Object IO.Pipes.NamedPipeClientStream('.',$disconnect.Pipe,[IO.Pipes.PipeDirection]::InOut);$partialPipe.Connect(3000)
 $partialWriter=New-Object IO.StreamWriter($partialPipe);$partialWriter.AutoFlush=$true
 $partialWriter.WriteLine('{"command":"snapshot","takeoverReady":true}')
 $prefix=New-Object byte[] 32;[void]$partialPipe.Read($prefix,0,$prefix.Length)
 $partialPipe.Dispose()
 Start-Sleep -Milliseconds 300
 Check (-not $disconnect.Process.HasExited) 'Disconnect during large snapshot write cannot crash bridge in writer disposal'
 Check ((Barrier $disconnect).method -eq 'mock/barrier') 'Stdio survives partial snapshot response disconnect'
 foreach($invalidQuestion in @($null,7,'future-question-shape')){
  $invalidAsync=Async ('invalid-'+[guid]::NewGuid().ToString('N'));$invalidAsync.params.item.questions=@($invalidQuestion)
  Emit $disconnect $invalidAsync
  Check ((Read $disconnect.Process.StandardOutput).params.item.id -ceq $invalidAsync.params.item.id) 'Non-object async question stays native without terminating output'
  Check ((Barrier $disconnect).method -eq 'mock/barrier') 'Transport survives unknown async question structure'
 }
 $off=StartCase 'disabled-start' $true $false $true;Emit $off (Traditional 31);Check ((Read $off.Process.StandardOutput).id -eq 31) 'Disabled at startup never opens takeover path'
 $wrongCase=StartCase 'wrong-api-home' $true $true
 Check ($wrongCase.Process.WaitForExit(4000) -and $wrongCase.Process.ExitCode -ne 0) 'Wrong/official CODEX_HOME cannot launch bound API proxy'
 Write-Output "PASSED: $passed takeover protocol checks. Isolated artifacts: $root"
}finally{
 foreach($case in $cases){try{if(-not $case.Process.HasExited){$case.Writer.Close();if(-not $case.Process.WaitForExit(4000)){$case.Process.Kill();$case.Process.WaitForExit()}}}catch{};try{$case.Process.Dispose()}catch{}}
 [Console]::InputEncoding=$originalEncoding
}
