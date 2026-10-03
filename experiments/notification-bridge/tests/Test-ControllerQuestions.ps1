$ErrorActionPreference='Stop'
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
$output=Join-Path $repo ('test-results\controller-questions-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($output)
$fake=Join-Path $output 'Fake.exe'; & "$PSScriptRoot\Build-FakeAppServer.ps1" -Destination $fake|Out-Null
$trial=Join-Path $output 'Trial'; & "$experiment\New-BridgeTrial.ps1" -Destination $trial -RealCli $fake -DesktopExecutable $fake|Out-Null
& "$trial\Enable-BridgeTrial.ps1"|Out-Null
$m=Read-BridgeTrial $trial
$api=[pscustomobject]@{id=('b'*32);role='api';home=$m.apiHome;profile=$m.profile}
$config=[pscustomobject]@{stateDirectory=(Join-Path $output 'state');instances=@([pscustomobject]@{id=('a'*32);role='official';home=(Join-Path $output 'Official')},$api)}
[void][IO.Directory]::CreateDirectory($config.stateDirectory)
$ConfigPath=Join-Path $output 'controller.local.json';$SmokeTest=$true;$script:completionReady=$true
$script:preferences=Read-ControllerPreferences $config;$script:uiBusy=$false;$script:openBusy=$false
$panel=New-Object CodexDual.ShellForm;$panel.ClientSize=New-Object Drawing.Size(840,548);$panel.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5)
function Set-UiMessage([string]$Message){$script:lastMessage=$Message}
function Update-PanelStatus{}
function Show-Error($Record){throw $Record}
$script:passed=0
function Check($value,[string]$name){if(-not $value){throw ('FAIL: '+$name)};$script:passed++;Write-Output ('PASS: '+$name)}
function PumpUntil([scriptblock]$condition,[string]$name){$end=[DateTime]::UtcNow.AddSeconds(9);do{[Windows.Forms.Application]::DoEvents();Update-PendingQuestions;Update-NotificationView;if(& $condition){return};Start-Sleep -Milliseconds 15}while([DateTime]::UtcNow -lt $end);throw ('Timeout: '+$name+' / '+$script:questionStatus)}
function ReadNative { $read=$process.StandardOutput.ReadLineAsync();if(-not $read.Wait(4000)){throw 'No fixture response'};return ($read.Result|ConvertFrom-Json) }
$start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=Join-Path $trial 'BridgeProxy.exe';$start.Arguments='app-server';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$start.EnvironmentVariables['CODEX_HOME']=$m.apiHome
$process=[Diagnostics.Process]::Start($start)
try{
    [void](ReadNative);[void](ReadNative);[void](ReadNative)
    Initialize-CompletionNotifications
    Initialize-NotificationsPage $panel;$script:notificationsPage.Visible=$true;$panel.Show()
    $api.home=Join-Path $output 'WrongHome';$rejected=$false;try{Connect-QuestionBridge $trial}catch{$rejected=$true};$api.home=$m.apiHome
    Check $rejected 'Mismatched API home cannot connect to the bridge'
    Connect-QuestionBridge $trial -Persist
    PumpUntil {$script:questionPending.Count -eq 1} 'question arrival'
    Check ($script:notificationListMode -eq 'pending' -and $script:pendingTab.Text -like '*1*') 'Question appears in the controller pending tab'
    Check ($script:questionNotice -and $script:questionNotice.Visible) 'New question opens a non-activating notice'
    Save-UiScreenshot $script:questionNotice (Join-Path $output 'question-notice.png')
    $script:questionNotice.Controls['NoticeBody'].PerformClick()
    Check ($script:questionWindow.Visible -and $script:questionPending.Count -eq 1 -and $script:questionNotice.IsDisposed) 'Clicking question card opens its answer window without submitting'
    $script:questionWindow.Close();Show-QuestionNotice $script:questionPending[0]
    $script:questionNotice.Controls['DismissNotice'].PerformClick()
    Check ($script:questionPending.Count -eq 1 -and -not $script:questionWindow.Visible) 'Question card close icon only dismisses the notice'
    Show-QuestionNotice $script:questionPending[0]
    Set-CompletionDisplaySettings 1 $false
    $notice=$script:questionNotice;$notice.Location=New-Object Drawing.Point(-10000,-10000);$panel.Activate()
    PumpUntil {$notice.IsDisposed} 'notice expires'
    Check ($script:questionPending.Count -eq 1) 'Auto-dismiss leaves question in the pending list'
    $token=$script:questionPending[0].requestToken
    Show-PendingQuestion $token
    $window=$script:questionWindow
    Check ($window.Visible -and -not $window.Controls.Find('SubmitAnswer',$true)[0].Enabled) 'Pending entry opens formal question window without default submission'
    $window.Close()
    Check (-not $window.Visible -and $script:questionPending.Count -eq 1) 'Closing answer window retains pending question'
    Show-PendingQuestion $token
    $window.Controls.Find('Option_choice_1',$true)[0].Checked=$true
    $window.Controls.Find('Answer_detail',$true)[0].Text='控制器回传测试'
    Check $window.TopMost 'Answer window stays above ordinary Codex windows'
    Clear-PendingQuestionState '模拟瞬时断线'
    Check ($window.Visible -and -not $window.IsRequestValid -and -not $window.Controls.Find('SubmitAnswer',$true)[0].Enabled) 'Connection loss retains the window and disables submission immediately'
    $script:questionPollAt=[DateTime]::MinValue
    PumpUntil {$window.IsRequestValid} 'same token recovery'
    Check ($window.Controls.Find('Option_choice_1',$true)[0].Checked -and $window.Controls.Find('Answer_detail',$true)[0].Text -ceq '控制器回传测试' -and $window.Controls.Find('SubmitAnswer',$true)[0].Enabled) 'Verified same-token snapshot restores answer controls and draft without reopening'
    Show-QuestionPreview
    $script:questionPreview.Controls.Find('Option_display_0',$true)[0].Checked=$true
    $script:questionPreview.Controls.Find('Answer_note',$true)[0].Text='希望收起提示后仍保留待处理问题。'
    $script:questionPreview.Controls.Find('SubmitAnswer',$true)[0].PerformClick()
    Check ($script:questionPreview.Controls.Find('QuestionStatus',$true)[0].Text -like '*答案未发送*' -and $script:questionPending.Count -eq 1) 'Preview is independent from real pending questions'
    Set-ControllerAppearance -Mode dark -Accent blue
    Save-UiScreenshot $script:questionPreview (Join-Path $output 'preview-dark.png')
    Save-UiScreenshot $window (Join-Path $output 'question-dark.png');Save-UiScreenshot $script:notificationsPage (Join-Path $output 'pending-dark.png')
    Set-ControllerAppearance -Mode light -Accent blue
    Save-UiScreenshot $script:questionPreview (Join-Path $output 'preview-light.png');$script:questionPreview.Hide()
    Save-UiScreenshot $window (Join-Path $output 'question-light.png');Save-UiScreenshot $script:notificationsPage (Join-Path $output 'pending-light.png')
    Check ($window.BackColor -eq [CodexDual.AppTheme]::Background) 'Open question window follows controller appearance'
    PumpUntil {-not $script:questionClient.Busy} 'poll completes'
    # Feed an incomplete aggregate through the real controller update path.
    # Another healthy endpoint must not prove this question was answered.
    $realClient=$script:questionClient;$pendingBefore=@($script:questionPending)
    Show-QuestionNotice $script:questionPending[0]
    $uncertainNotice=$script:questionNotice
    try{
        $script:questionClient=[pscustomobject]@{Busy=$true;Reply=[pscustomobject]@{Kind='snapshot';Token='';Error=$null;Json='{"ok":true,"pending":[],"unavailableConnections":0,"confirmedConnections":["other-connection"]}'}}
        $script:questionClient|Add-Member ScriptMethod Take {$value=$this.Reply;$this.Reply=$null;return $value}
        Update-PendingQuestions
        Check ($window.Visible -and $uncertainNotice.Visible -and -not $window.IsRequestValid -and $window.Controls.Find('Answer_detail',$true)[0].Text -ceq '控制器回传测试') 'Missing unconfirmed connection retains both surfaces and the exact draft'
        $script:questionClient.Reply=[pscustomobject]@{Kind='answer';Token=('f'*32);Error=$null;Json='{"ok":true}'}
        Update-PendingQuestions
        Check ($window.Visible -and $uncertainNotice.Visible) 'Late answer for a different token cannot close the current question or notice'
    }finally{$script:questionClient=$realClient;$script:questionPending=$pendingBefore}
    $script:questionPollAt=[DateTime]::MinValue
    PumpUntil {$window.IsRequestValid -and -not $script:questionClient.Busy} 'confirmed question restores after missing endpoint'
    Show-QuestionNotice $script:questionPending[0]
    $answerNotice=$script:questionNotice
    $window.Controls.Find('SubmitAnswer',$true)[0].PerformClick()
    PumpUntil {$script:questionPending.Count -eq 0} 'answer result'
    Check (-not $window.Visible -and $answerNotice.IsDisposed) 'Successful answer closes its window and notice in the same result update without an expiry delay'
    $events=@((ReadNative),(ReadNative));$received=@($events|Where-Object {$_.method -eq 'mock/received'})[0]
    if(-not $received.params.message.PSObject.Properties['result']){throw ('Unexpected fixture response: '+($received|ConvertTo-Json -Depth 8 -Compress))}
    Check ($received.params.message.result.answers.choice.answers[0] -eq 'B' -and $received.params.message.result.answers.detail.answers[0] -ceq '控制器回传测试') 'Formal UI answer reaches the proxy with exact selection and Unicode'
    Check (-not $window.Controls.Find('SubmitAnswer',$true)[0].Enabled) 'Answered question cannot be submitted again'
    $script:preferences['windowBehavior']=@{panelMode='focus';panelOverlay=$false;questionMode='passive';questionOverlay=$true}
    $panel.Activate();[Windows.Forms.Application]::DoEvents();$foregroundBefore=[CodexDual.Native]::Foreground()
    $process.StandardInput.WriteLine('{"method":"mock/reuse"}');[void](ReadNative)
    PumpUntil {$script:questionPending.Count -eq 1} 'next question'
    $next=$script:questionPending[0].requestToken;Check ($next -ne $token) 'Reused request ID becomes a distinct pending question'
    Check ($window.Visible -and $window.RequestToken -ceq $next -and [CodexDual.Native]::Foreground() -eq $foregroundBefore) 'Automatic passive mode opens the new question without moving foreground focus'
    $returnThread=[guid]::NewGuid().ToString();$script:questionPending[0].threadId=$returnThread
    $script:returnTarget=$null
    function Open-CompletionTarget($Instance,[string]$ThreadId){$script:returnTarget=@{id=$Instance.id;thread=$ThreadId}}
    Show-PendingQuestion $next
    $window.Controls.Find('ReturnToCodex',$true)[0].PerformClick()
    Check (-not $window.Visible -and $script:returnTarget.id -eq $api.id -and $script:returnTarget.thread -eq $returnThread) 'Return action hides the compact question and targets only its API task'
    Show-PendingQuestion $next
    $process.StandardInput.WriteLine('{"method":"mock/resolve"}');[void](ReadNative)
    PumpUntil {$script:questionPending.Count -eq 0} 'native resolve'
    Check (-not $window.Visible -and -not $window.Controls.Find('SubmitAnswer',$true)[0].Enabled) 'Native resolution closes the visible answer window at the next verified snapshot'
    $script:preferences.windowBehavior.questionMode='focus'
    $process.StandardInput.WriteLine('{"method":"mock/reuse"}');[void](ReadNative)
    PumpUntil {$script:questionPending.Count -eq 1 -and $window.Visible} 'automatic focused question'
    Check ([CodexDual.Native]::Foreground() -eq $window.Handle -and $window.AnswerJson -eq $null) 'Automatic focus mode foregrounds the question without generating an answer'
    & "$trial\Rollback-ApiBridge.ps1"|Out-Null
    PumpUntil {$script:questionStatus -like '*已停用*'} 'rollback status'
    Check ($script:questionPending.Count -eq 0) 'Rollback clears pending UI without sending answers'
    $saved=Get-Content (Join-Path $config.stateDirectory 'question-bridge.local.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Check ($saved.instanceId -eq $api.id) 'Persisted connection is bound to the registered API instance'
}finally{
    Dispose-PendingQuestions;Dispose-CompletionNotifications;$panel.Dispose()
    if(-not $process.HasExited){$process.StandardInput.Close();if(-not $process.WaitForExit(5000)){$process.Kill()}};$process.Dispose()
}
Write-TrialJson (Join-Path $output 'result.json') @{passed=$script:passed;scope='controller-question-integration';trial=$trial}
Write-Output ('PASSED: '+$script:passed+' controller question checks. Output: '+$output)
