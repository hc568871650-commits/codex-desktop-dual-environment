$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\..\src\Panel.ps1"
. "$PSScriptRoot\..\src\CompletionNotifications.ps1"
$script:passed=0;$script:panelShows=0;$script:feedbacks=@();$script:focused=0;$script:completionReady=$true
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('notification-return-'+[guid]::NewGuid().ToString('N'))
$config=[pscustomobject]@{stateDirectory=$root;instances=@([pscustomobject]@{id=('b'*32);role='api'})}
$ConfigPath=Join-Path $root 'fixture.json';$SmokeTest=$true;$script:preferences=@{names=@{}};$script:statusCache=@{}
$script:openMenus=@{};$script:closeMenus=@{};$script:disabledForOpen=@();$script:uiBusy=$false
$panel=New-Object Windows.Forms.Form;$panel.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
function Check($value,[string]$message){if(-not $value){throw ('FAIL: '+$message)};$script:passed++;Write-Output ('PASS: '+$message)}
function Set-UiMessage([string]$Message){$script:lastMessage=$Message}
function Show-ControlPanel{$script:panelShows++;$panel.Show()}
function Update-PanelStatus{}
function Complete-InstanceOpen($Instance,$Process,$Windows){$script:focused++;return 'Shown'}
$script:openWork=New-Object CodexDual.BackgroundWork
$realFeedback=${function:Show-TaskNavigationFeedback}
function Show-TaskNavigationFeedback([string]$Message){$script:feedbacks+=,$Message}
function Wait-Result {
    $end=[DateTime]::UtcNow.AddSeconds(5)
    while(-not $script:openWork.Completed -and [DateTime]::UtcNow -lt $end){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    if(-not $script:openWork.Completed){throw 'Worker timeout'}
    Receive-PanelOpen
}
try{
    Initialize-CompletionNotifications
    $script:workCode="[pscustomobject]@{Role='api';Process=`$null;Windows=@();Error='';TaskOutcome='Unsupported';QuickIdentity=`$false}"
    Open-CompletionTarget $config.instances[0] ([guid]::NewGuid().ToString())
    Wait-Result
    Check ($script:focused -eq 1 -and $script:panelShows -eq 0 -and -not $panel.Visible) 'Unsupported task link still opens Codex without exposing the panel'
    Check ($script:feedbacks.Count -eq 1 -and $script:feedbacks[0] -like '*任务链接*') 'Unsupported navigation stays in lightweight feedback'
    $script:workCode="[pscustomobject]@{Role='api';Process=`$null;Windows=@();Error='fixture cannot open target';QuickIdentity=`$false}"
    Open-CompletionTarget $config.instances[0] ([guid]::NewGuid().ToString());Wait-Result
    Check ($script:panelShows -eq 0 -and $script:feedbacks.Count -eq 2) 'Notification open error never shows the panel'
    $script:workCode="throw 'fixture worker failure'"
    Open-CompletionTarget $config.instances[0] ([guid]::NewGuid().ToString());Wait-Result
    Check ($script:panelShows -eq 0 -and $script:feedbacks.Count -eq 3 -and -not $script:openFromNotification -and -not $script:openBusy) 'Worker exception preserves hidden panel and resets action context'
    $script:workCode="[pscustomobject]@{Role='api';Process=`$null;Windows=@();Error='';TaskOutcome='';QuickIdentity=`$false}"
    Open-CompletionTarget $config.instances[0] '';Wait-Result
    Check ($script:focused -eq 2 -and $script:panelShows -eq 0) 'Notification without task ID opens only its environment'
    $script:workCode="[pscustomobject]@{Role='api';Process=`$null;Windows=@();Error='fixture regular action error';QuickIdentity=`$false}"
    Start-PanelOpen @('api');Wait-Result
    Check ($script:panelShows -eq 1) 'Explicit ordinary controller actions keep their existing error behavior'
    $panel.Hide();Set-Item function:Show-TaskNavigationFeedback $realFeedback
    Show-TaskNavigationFeedback '测试：已返回 API 环境，请在那里选择任务。'
    [Windows.Forms.Application]::DoEvents()
    Check ($script:navigationFeedback.Visible -and -not $panel.Visible -and -not $script:navigationFeedback.ShowInTaskbar) 'Real feedback is a separate corner card, not the control panel'
    Close-CompletionCards
    Check $script:navigationFeedback.IsDisposed 'Dismiss-all also closes navigation feedback'
}finally{$script:openWork.Dispose();Dispose-CompletionNotifications;$panel.Dispose()}
Write-Output ('PASSED: '+$script:passed+' notification return checks.')
