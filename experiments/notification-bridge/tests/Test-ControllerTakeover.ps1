$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Use Windows PowerShell 5.1 -STA.'}
$experiment=Split-Path $PSScriptRoot -Parent
$repo=[IO.Path]::GetFullPath((Join-Path $experiment '..\..'))
. "$experiment\Trial.Common.ps1"
. "$repo\src\Instances.ps1"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$repo\src\Panel.ps1"
. "$repo\src\CompletionNotifications.ps1"
. "$repo\src\PendingQuestions.ps1"
. "$repo\src\WorkspacePages.ps1"
[Windows.Forms.Application]::EnableVisualStyles()
$output=Join-Path $repo ('test-results\controller-takeover-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($output)
$script:passed=0;$script:checks=New-Object Collections.ArrayList;$script:failure=$null
$panel=$null;$process=$null;$writer=$null;$notificationsInitialized=$false
$nativeStatusPattern='*'+[char]0x539F+[char]0x751F+'*'
Start-Transcript -Path (Join-Path $output 'test.log') | Out-Null
function Check($value,[string]$name){
    [void]$script:checks.Add(@{name=$name;passed=[bool]$value})
    if(-not $value){throw ('FAIL: '+$name)}
    $script:passed++;Write-Output ('PASS: '+$name)
}
function Tick {
    [Windows.Forms.Application]::DoEvents()
    Update-PendingQuestions
    Update-NotificationView
}
function PumpUntil([scriptblock]$condition,[string]$name){
    $end=[DateTime]::UtcNow.AddSeconds(9)
    do{Tick;if(& $condition){return};Start-Sleep -Milliseconds 15}while([DateTime]::UtcNow -lt $end)
    throw ('Timeout: '+$name+' / '+$script:questionStatus)
}
function ReadNative([switch]$NoPump){
    $read=$process.StandardOutput.ReadLineAsync();$end=[DateTime]::UtcNow.AddSeconds(4)
    while(-not $read.IsCompleted -and [DateTime]::UtcNow -lt $end){if(-not $NoPump){Tick};Start-Sleep -Milliseconds 15}
    if(-not $read.IsCompleted){throw 'No fixture response'}
    if($null -eq $read.Result){throw 'Fixture EOF'}
    return ($read.Result|ConvertFrom-Json)
}
function SendNative($message){$writer.WriteLine(($message|ConvertTo-Json -Depth 30 -Compress))}
function NewQuestion([string]$item,[string]$thread,[string]$turn){
    return @{method='item/started';params=@{threadId=$thread;turnId=$turn;item=@{
        type='agentMessage';id=$item;text='Keep the ordinary agent text';phase='commentary';delivery='async'
        questions=@(@{title='Select an option';options=@('A','B')},@{title='Add a detail';options=@()})
    }}}
}
function EmitQuestion($message){SendNative @{method='mock/emit';params=@{message=$message}};return ReadNative}
function Ready {
    $script:questionPollAt=[DateTime]::MinValue
    PumpUntil {$script:questionStatus -like '*API*' -and $script:questionStatus -notlike $nativeStatusPattern -and -not $script:questionClient.Busy} 'active takeover lease'
}
function FillAnswer($window,[string]$text){
    $window.Controls.Find('Option_0_1',$true)[0].Checked=$true
    $window.Controls.Find('Answer_1',$true)[0].Text=$text
    Check $window.Controls.Find('SubmitAnswer',$true)[0].Enabled 'Completed real editors enable submit'
}
function Set-UiMessage([string]$Message){$script:lastMessage=$Message}
function Update-PanelStatus{}
function Show-Error($Record){throw $Record}
try{
    $fake=Join-Path $output 'TakeoverFixture.exe'
    $compiler=New-Object Microsoft.CSharp.CSharpCodeProvider
    $options=New-Object CodeDom.Compiler.CompilerParameters;$options.GenerateExecutable=$true;$options.OutputAssembly=$fake
    foreach($assembly in @('System.dll','System.Core.dll','System.Web.Extensions.dll')){[void]$options.ReferencedAssemblies.Add($assembly)}
    try{$built=$compiler.CompileAssemblyFromFile($options,(Join-Path $PSScriptRoot 'TakeoverFixture.cs'));if($built.Errors.HasErrors){throw ($built.Errors|Out-String)}}finally{$compiler.Dispose()}
    $trial=Join-Path $output 'Trial'
    & "$experiment\New-BridgeTrial.ps1" -Destination $trial -RealCli $fake -DesktopExecutable $fake | Out-Null
    $bridgeConfig=Get-Content (Join-Path $trial 'bridge.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $bridgeConfig | Add-Member NoteProperty takeoverQuestions $true -Force
    Write-TrialJson (Join-Path $trial 'bridge.config.json') $bridgeConfig
    & "$trial\Enable-BridgeTrial.ps1" | Out-Null
    $m=Read-BridgeTrial $trial
    $api=[pscustomobject]@{id=('b'*32);role='api';home=$m.apiHome;profile=$m.profile}
    $config=[pscustomobject]@{stateDirectory=(Join-Path $output 'state');instances=@([pscustomobject]@{id=('a'*32);role='official';home=(Join-Path $output 'Official')},$api)}
    [void][IO.Directory]::CreateDirectory($config.stateDirectory)
    $ConfigPath=Join-Path $output 'controller.local.json';$SmokeTest=$true;$script:completionReady=$true
    $script:preferences=Read-ControllerPreferences $config
    $script:preferences.windowBehavior=@{panelMode='focus';panelOverlay=$false;questionMode='passive';questionOverlay=$true}
    $script:uiBusy=$false;$script:openBusy=$false
    $panel=New-Object CodexDual.ShellForm;$panel.Text='Isolated takeover foreground fixture';$panel.ClientSize=New-Object Drawing.Size(840,548);$panel.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5)
    $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=Join-Path $trial 'BridgeProxy.exe';$start.Arguments='app-server';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$start.EnvironmentVariables['CODEX_HOME']=$m.apiHome
    $process=[Diagnostics.Process]::Start($start)
    $writer=New-Object IO.StreamWriter($process.StandardInput.BaseStream,(New-Object Text.UTF8Encoding($false)));$writer.AutoFlush=$true
    Initialize-CompletionNotifications
    $notificationsInitialized=$true
    Initialize-NotificationsPage $panel;$script:notificationsPage.Visible=$true;$panel.Show();$panel.Activate()
    Connect-QuestionBridge $trial
    Ready
    Check ($script:questionPending.Count -eq 0) 'Ready controller owns an empty live takeover lease before emission'
    $thread=[guid]::NewGuid().ToString();$turn=[guid]::NewGuid().ToString()
    $panel.Activate();[Windows.Forms.Application]::DoEvents();$foreground=[CodexDual.Native]::Foreground()
    Check ($foreground -eq $panel.Handle) 'Test-owned panel establishes real foreground before passive arrival'
    $first=NewQuestion 'ui-success' $thread $turn;$native=EmitQuestion $first
    Check ($null -eq $native.params.item.questions -and $native.params.item.text -ceq $first.params.item.text) 'Active takeover removes native questions while preserving ordinary message text'
    PumpUntil {$script:questionPending.Count -eq 1 -and $script:questionWindow -and $script:questionWindow.Visible} 'passive question appears'
    $window=$script:questionWindow;$token=$window.RequestToken
    Check ($script:questionPending[0].delivery -eq 'exclusive' -and [CodexDual.Native]::Foreground() -eq $foreground) 'Automatic passive question is exclusive and preserves foreground'
    $answer='controller detail '+[char]0x4E2D+[char]0x6587
    FillAnswer $window $answer
    Save-UiScreenshot $window (Join-Path $output 'passive-answer.png')
    PumpUntil {-not $script:questionClient.Busy} 'snapshot idle before answer'
    $window.Controls.Find('SubmitAnswer',$true)[0].PerformClick()
    $steer=ReadNative;$rpc=$steer.params.message
    Check ($steer.method -eq 'mock/steer' -and $rpc.method -eq 'turn/steer' -and $rpc.params.threadId -eq $thread -and $rpc.params.expectedTurnId -eq $turn -and $rpc.id -like 'codex-bridge-steer:*') 'UI submission emits exact-thread turn/steer with unique internal ID and turn precondition'
    $wrapped=$rpc.params.input[0].text
    Check ($wrapped.StartsWith("<send_user_message_question_reply>`n") -and $wrapped.EndsWith("`n</send_user_message_question_reply>")) 'Async answer uses native reply wrapper'
    $reply=($wrapped -replace '^<send_user_message_question_reply>\n','' -replace '\n</send_user_message_question_reply>$','') | ConvertFrom-Json
    Check ($reply.Count -eq 2 -and $reply[0].questionItemId -ceq '["request_user_input_async","ui-success",0]' -and $reply[0].answer -ceq 'B' -and $reply[1].questionItemId -ceq '["request_user_input_async","ui-success",1]' -and $reply[1].answer -ceq $answer) 'Wrapper preserves option, Unicode free text and each exact async question identity'
    PumpUntil {$script:questionPending.Count -eq 0 -and -not $window.IsRequestValid} 'successful steer acknowledgement'
    Check (-not $window.Visible -and -not $window.Controls.Find('SubmitAnswer',$true)[0].Enabled) 'Successful acknowledged answer closes the formal UI immediately and disables repeat submit'
    Ready
    $returnThread=[guid]::NewGuid().ToString();$returnTurn=[guid]::NewGuid().ToString()
    $second=NewQuestion 'ui-return' $returnThread $returnTurn
    $native=EmitQuestion $second
    Check ($null -eq $native.params.item.questions) 'Second question starts with only external ownership'
    PumpUntil {$script:questionPending.Count -eq 1 -and $window.Visible -and $window.RequestToken -cne $token} 'return question appears'
    $script:returnTarget=$null;$script:releasedNative=$null
    function Open-CompletionTarget($Instance,[string]$ThreadId){
        # release emits the original native projection before returning its pipe
        # acknowledgement; inspect stdout inside the target callback to prove order.
        $script:releasedNative=ReadNative -NoPump
        $script:returnTarget=@{id=$Instance.id;thread=$ThreadId;visible=$script:questionWindow.Visible}
    }
    PumpUntil {-not $script:questionClient.Busy} 'snapshot idle before return'
    $window.Controls.Find('ReturnToCodex',$true)[0].PerformClick()
    PumpUntil {$null -ne $script:returnTarget} 'release then open original task'
    Check ($script:releasedNative.method -eq 'item/started' -and $script:releasedNative.params.item.id -eq 'ui-return' -and $script:releasedNative.params.item.questions.Count -eq 2 -and $script:releasedNative.params.threadId -eq $returnThread) 'Native original questions are restored before Open-CompletionTarget runs'
    Check ($script:returnTarget.id -eq $api.id -and $script:returnTarget.thread -eq $returnThread -and -not $script:returnTarget.visible -and -not $window.Visible -and $script:questionPending.Count -eq 0) 'Return targets only the exact API thread after release and hides the compact UI'
    Ready
    SendNative @{method='mock/mode';params=@{mode='hold'}}
    Check ((ReadNative).method -eq 'mock/ack') 'Fixture hold mode acknowledges setup'
    $unknownThread=[guid]::NewGuid().ToString();$unknownTurn=[guid]::NewGuid().ToString()
    $third=NewQuestion 'ui-unknown' $unknownThread $unknownTurn;$native=EmitQuestion $third
    Check ($null -eq $native.params.item.questions) 'Held-answer question is exclusively captured'
    PumpUntil {$script:questionPending.Count -eq 1 -and $window.Visible -and $script:questionPending[0].itemId -eq 'ui-unknown'} 'held question appears'
    $draft='keep this exact draft '+[char]0x4E2D
    FillAnswer $window $draft
    PumpUntil {-not $script:questionClient.Busy} 'snapshot idle before held answer'
    $window.Controls.Find('SubmitAnswer',$true)[0].PerformClick()
    $held=ReadNative
    Check ($held.method -eq 'mock/steer' -and $held.params.count -eq 2) 'Held submission emits one steer without an acknowledgement'
    PumpUntil {$script:questionPending.Count -eq 1 -and [bool](Get-ObjectValue $script:questionPending[0] 'outcomeUnknown' $false) -and -not $window.IsRequestValid} 'timeout becomes unknown snapshot state'
    Check ($window.Visible -and -not $window.Controls.Find('SubmitAnswer',$true)[0].Enabled -and $window.Controls.Find('Option_0_1',$true)[0].Checked -and $window.Controls.Find('Answer_1',$true)[0].Text -ceq $draft) 'Unknown outcome keeps the window visible, disables resubmission and retains selected option and exact draft'
    Save-UiScreenshot $window (Join-Path $output 'outcome-unknown.png')
    $window.Controls.Find('SubmitAnswer',$true)[0].PerformClick()
    SendNative @{method='mock/barrier'};$barrier=ReadNative
    Check ($barrier.method -eq 'mock/barrier' -and $barrier.params.count -eq 2) 'Disabled UI cannot emit a second steer after timeout'
    SendNative @{method='mock/late'}
    Check ((ReadNative).method -eq 'mock/late-done') 'Late successful acknowledgement is consumed internally by the proxy'
    PumpUntil {$script:questionPending.Count -eq 0 -and -not $window.IsRequestValid} 'late acknowledgement resolves unknown pending'
    Check (-not $window.Visible -and -not $window.Controls.Find('SubmitAnswer',$true)[0].Enabled -and $window.Controls.Find('Answer_1',$true)[0].Text -ceq $draft) 'Late successful acknowledgement closes the window through snapshot recovery while leaving the draft intact'
    $script:completionSettings.enabled=$false;$script:questionPollAt=[DateTime]::MinValue
    Ready
    $paused=NewQuestion 'notifications-paused' ([guid]::NewGuid().ToString()) ([guid]::NewGuid().ToString())
    $native=EmitQuestion $paused
    PumpUntil {$script:questionPending.Count -eq 1 -and $script:questionPending[0].itemId -eq 'notifications-paused'} 'paused notifications retain pending takeover'
    Check ($null -eq $native.params.item.questions -and $script:questionPending[0].delivery -eq 'exclusive' -and -not $window.Visible -and (-not $script:questionNotice -or -not $script:questionNotice.Visible)) 'Disabled notifications retain exclusive pending questions without native leakage, automatic window or notice'
    # Native HWND/profile ownership is covered by Test-FastRestore. Control that
    # boundary here to verify the real lease, protocol replay and actual controls.
    $script:fixtureApiForeground=$true
    function Test-CompletionForeground($Instance){return $script:fixtureApiForeground}
    $script:questionPollAt=[DateTime]::MinValue
    PumpUntil {$script:questionNativeForeground -and $script:questionPending.Count -eq 0 -and -not $script:questionClient.Busy} 'foreground releases existing background question'
    $released=ReadNative
    Check ($released.params.item.id -eq 'notifications-paused' -and $released.params.item.questions.Count -eq 2) 'Foreground transfers existing pending question back to native even while notifications are paused'
    $script:completionSettings.enabled=$true
    $front=NewQuestion 'foreground-native' ([guid]::NewGuid().ToString()) ([guid]::NewGuid().ToString())
    $native=EmitQuestion $front
    Check ($native.params.item.questions.Count -eq 2 -and $native.params.item.text -ceq $front.params.item.text) 'New foreground async question remains intact in native Desktop protocol'
    $sync=@{id=899;method='item/tool/requestUserInput';params=@{threadId=[guid]::NewGuid().ToString();turnId=[guid]::NewGuid().ToString();itemId='foreground-sync';questions=@(@{id='sync-q';header='Check';question='Native sync test';isOther=$true;isSecret=$false;options=@(@{label='A';description='First'},@{label='B';description='Second'})})}}
    $native=EmitQuestion $sync
    Check ($native.method -eq 'item/tool/requestUserInput' -and $native.id -eq 899 -and $native.params.questions[0].id -eq 'sync-q') 'New foreground synchronous question retains original native request and answer identity'
    PumpUntil {-not $script:questionClient.Busy} 'foreground snapshot settles'
    Check ($script:questionPending.Count -eq 0 -and -not $window.Visible -and (-not $script:questionNotice -or -not $script:questionNotice.Visible)) 'Foreground question creates neither external notice nor answer window'
    $script:fixtureApiForeground=$false;$script:questionPollAt=[DateTime]::MinValue;Ready
    Check ($script:questionPending.Count -eq 0 -and -not $window.Visible) 'Going to background does not steal an already native question'
    $background=NewQuestion 'background-after-native' ([guid]::NewGuid().ToString()) ([guid]::NewGuid().ToString())
    $native=EmitQuestion $background
    PumpUntil {$window.Visible -and $script:questionPending.Count -eq 1} 'new background question opens external window'
    Check ($null -eq $native.params.item.questions -and $script:questionPending[0].itemId -eq 'background-after-native') 'New background question again uses exclusive external UI'
    FillAnswer $window 'draft survives foreground transfer'
    $script:fixtureApiForeground=$true;$script:questionPollAt=[DateTime]::MinValue
    PumpUntil {$script:questionPending.Count -eq 0 -and -not $window.Visible} 'returning foreground restores native and hides external UI'
    $released=ReadNative
    Check ($released.params.item.questions.Count -eq 2 -and $released.params.item.id -eq 'background-after-native') 'Returning to API foreground replays the native question before clearing external ownership'
    Check ($window.Controls.Find('Answer_1',$true)[0].Text -ceq 'draft survives foreground transfer' -and -not $window.Controls.Find('SubmitAnswer',$true)[0].Enabled) 'Transferred external draft is retained but cannot submit a duplicate answer'
    $script:fixtureApiForeground=$false;$script:questionPollAt=[DateTime]::MinValue;Ready
    $race=NewQuestion 'foreground-arrival-race' ([guid]::NewGuid().ToString()) ([guid]::NewGuid().ToString())
    $native=EmitQuestion $race
    $script:fixtureApiForeground=$true
    $raceEnd=[DateTime]::UtcNow.AddSeconds(4);$appeared=$false
    do{Tick;if($window.Visible -or ($script:questionNotice -and $script:questionNotice.Visible)){$appeared=$true};Start-Sleep -Milliseconds 15}while([DateTime]::UtcNow -lt $raceEnd)
    $released=ReadNative
    Check (-not $appeared -and $released.params.item.id -eq 'foreground-arrival-race' -and $released.params.item.questions.Count -eq 2) 'Foreground change during pending snapshot restores native without briefly opening external UI'
    SendNative @{method='mock/barrier'}
    Check ((ReadNative).method -eq 'mock/barrier') 'Foreground transfer emits no duplicate native question'
}catch{$script:failure=$_.Exception.Message;Write-Output ($_ | Out-String);throw}
finally{
    Dispose-PendingQuestions
    if($notificationsInitialized){Dispose-CompletionNotifications}
    if($panel){$panel.Dispose()}
    if($process){try{if(-not $process.HasExited){if($writer){$writer.Close()};if(-not $process.WaitForExit(4000)){$process.Kill();$process.WaitForExit()}}}finally{$process.Dispose()}}
    Write-TrialJson (Join-Path $output 'result.json') @{passed=$script:passed;checkCount=$script:checks.Count;checks=@($script:checks);error=$script:failure;scope='isolated-controller-takeover-ui';screenshots=@('passive-answer.png','outcome-unknown.png')}
    Write-Output ('CHECKS: '+$script:checks.Count+'; PASSED: '+$script:passed+'; Output: '+$output)
    Stop-Transcript | Out-Null
}
