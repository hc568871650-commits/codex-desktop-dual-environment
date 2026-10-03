$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\..\src\Panel.ps1"
. "$PSScriptRoot\..\src\CompletionNotifications.ps1"
. "$PSScriptRoot\..\src\WorkspacePages.ps1"
$script:passed=0
function Check($Value,$Message){if(-not $Value){throw ('FAIL: '+$Message)};$script:passed++;Write-Output ('PASS: '+$Message)}
function Invoke-DisplayDialogChoice([int]$Choice,[int]$Seconds,[bool]$Fade,[int]$ExpectedInitial,[string]$Screenshot='') {
    $state=@{clicked=$false;initial=-1;error=$null;timedOut=$false}
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    $dialogTimer=New-Object Windows.Forms.Timer;$dialogTimer.Interval=40
    $dialogTimer.Add_Tick({
        $dialog=@([Windows.Forms.Application]::OpenForms|Where-Object {$_.Text -eq '通知显示设置'})
        if($dialog.Count -ne 1 -or $state.clicked){return}
        $state.clicked=$true
        try{
            $state.initial=$dialog[0].Controls['DisplayDuration'].SelectedIndex
            if($Screenshot){Save-UiScreenshot $dialog[0] $Screenshot}
            $dialog[0].Controls['DisplayDuration'].SelectedIndex=$Choice
            if($Choice -eq 5){$dialog[0].Controls['CustomSeconds'].Value=$Seconds}
            $dialog[0].Controls['FadeAnimation'].Checked=$Fade
            $dialog[0].Controls['SaveDisplay'].PerformClick()
        }catch{
            $state.error=$_
            $dialog[0].Close()
        }
    }.GetNewClosure())
    $watchdog=New-Object Windows.Forms.Timer;$watchdog.Interval=100
    $watchdog.Add_Tick({
        if([DateTime]::UtcNow -lt $deadline){return}
        $state.timedOut=$true
        $dialog=@([Windows.Forms.Application]::OpenForms|Where-Object {$_.Text -eq '通知显示设置'})
        if($dialog.Count -eq 1){$dialog[0].Close()}
    }.GetNewClosure())
    try{$watchdog.Start();$dialogTimer.Start();Show-NotificationDisplaySettings}finally{
        $dialogTimer.Stop();$dialogTimer.Dispose();$watchdog.Stop();$watchdog.Dispose()
    }
    if($state.error){throw ('Display settings dialog callback failed: '+$state.error)}
    if($state.timedOut){throw 'Display settings dialog did not close within 10 seconds'}
    Check ($state.clicked -and $state.initial -eq $ExpectedInitial) ('Display settings reopens with saved selection (actual='+$state.initial+', expected='+$ExpectedInitial+')')
}
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('notifications-ui-'+[Guid]::NewGuid().ToString('N'))
$config=[pscustomobject]@{stateDirectory=$root;instances=@([pscustomobject]@{id=('a'*32);role='official'},[pscustomobject]@{id=('b'*32);role='api'})}
$ConfigPath=Join-Path $root 'fixture.local.json';$SmokeTest=$true
$script:preferences=@{names=@{}};$script:uiBusy=$false;$script:opened=@()
$panel=New-Object Windows.Forms.Form;$panel.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
function Update-PanelStatus {}
function Show-Error($ErrorRecord){throw $ErrorRecord}
function Set-UiMessage([string]$Message){$script:lastFeedback=$Message}
function Open-PanelInstance($Instance){$script:opened+=$Instance.id}
$script:taskLinks=@()
function Start-PanelOpen([string[]]$Roles,[string]$ThreadId,[switch]$FromNotification){if($ThreadId){$script:taskLinks+=@{roles=$Roles;threadId=$ThreadId;fromNotification=[bool]$FromNotification}}else{$script:opened+=@($config.instances|Where-Object {$_.role -eq $Roles[0]})[0].id}}
try{
    Initialize-CompletionNotifications
    Check ($null -eq $script:completionWorker) 'Smoke mode creates no worker process'
    Check ($script:completionSettings.displaySeconds -eq 15 -and -not $script:completionSettings.fadeEnabled) 'Default display is 15 seconds without animation'
    Save-CompletionSettings $config ([pscustomobject]@{schema=1;enabled=$true;epoch=$script:completionSettings.epoch})
    $legacy=Read-CompletionSettings $config
    Check ($legacy.displaySeconds -eq 15 -and -not $legacy.fadeEnabled) 'Legacy notification settings inherit display defaults'
    Set-CompletionDisplaySettings 0 $false
    Check ((Read-CompletionSettings $config).displaySeconds -eq 0 -and -not (Read-CompletionSettings $config).fadeEnabled) 'Persistent mode and animation preference survive reload'
    $invalid=$false
    try{Set-CompletionDisplaySettings 3601 $true}catch{$invalid=$true}
    Check ($invalid -and (Read-CompletionSettings $config).displaySeconds -eq 0) 'Out-of-range custom duration cannot overwrite saved settings'
    Show-CompletionPreview
    $persistent=$script:completionCards[0]
    Check ($persistent.AutoDismissMilliseconds -eq 0 -and -not $persistent.FadeEnabled) 'Preview uses saved persistent mode and animation preference'
    $pauseUntil=[DateTime]::UtcNow.AddMilliseconds(700)
    while([DateTime]::UtcNow -lt $pauseUntil){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    Check (-not $persistent.IsDisposed -and $persistent.Opacity -eq 1) 'Persistent card stays visible without fade until manually closed'
    Close-CompletionCards
    Set-CompletionDisplaySettings 15 $false
    Invoke-DisplayDialogChoice 5 42 $true 3 (Join-Path $root 'display-settings.png')
    Check ((Read-CompletionSettings $config).displaySeconds -eq 42 -and (Read-CompletionSettings $config).fadeEnabled) 'Display settings dialog saves custom seconds and animation toggle'
    Invoke-DisplayDialogChoice 1 0 $false 5
    Check ((Read-CompletionSettings $config).displaySeconds -eq 5 -and -not (Read-CompletionSettings $config).fadeEnabled) 'Preset duration saves through dialog'
    Invoke-DisplayDialogChoice 6 0 $false 1
    Check ((Read-CompletionSettings $config).displaySeconds -eq 0) 'Permanent mode saves through dialog'
    Invoke-DisplayDialogChoice 3 0 $false 6
    Set-CompletionDisplaySettings 15 $false
    $animated=New-Object CodexDual.CompletionCard;$animated.StartPosition='Manual';$animated.Location=New-Object Drawing.Point(-10000,-10000);$animated.ShowInTaskbar=$false
    $animated.SetDisplaySettings(0,$true);$animated.Show()
    Check ($animated.Opacity -lt 1) ('Optional fade starts below full opacity (opacity='+$animated.Opacity+', enabled='+$animated.FadeEnabled+')')
    $fadeUntil=[DateTime]::UtcNow.AddMilliseconds(500)
    while([DateTime]::UtcNow -lt $fadeUntil){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    try{Check ($animated.Opacity -eq 1) 'Optional fade reaches full opacity'}finally{$animated.Dispose()}
    $rescue=New-Object CodexDual.CompletionCard;$rescue.StartPosition='Manual';$rescue.Location=New-Object Drawing.Point(-10000,-10000);$rescue.ShowInTaskbar=$false
    $rescue.SetDisplaySettings(350,$true);$rescue.Show()
    $deadline=[DateTime]::UtcNow.AddSeconds(2)
    while($rescue.Opacity -lt 1 -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    while($rescue.Opacity -ge 1 -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    Check (-not $rescue.IsDisposed -and $rescue.Opacity -lt 1) 'Expired animated card enters fade-out'
    $rescue.PauseDismissal=$true
    $deadline=[DateTime]::UtcNow.AddMilliseconds(400)
    while([DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    Check (-not $rescue.IsDisposed -and $rescue.Opacity -eq 1) 'Interaction during fade-out restores card'
    $rescue.PauseDismissal=$false
    $deadline=[DateTime]::UtcNow.AddSeconds(2)
    while($rescue.Opacity -ge 1 -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    Check (-not $rescue.IsDisposed -and $rescue.Opacity -lt 1) 'Resumed card can enter fade-out again'
    $rescue.SetDisplaySettings(0,$false)
    $deadline=[DateTime]::UtcNow.AddMilliseconds(550)
    while([DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    try{Check (-not $rescue.IsDisposed -and $rescue.Opacity -eq 1) 'Switching to permanent mode cancels a pending dismissal'}finally{$rescue.Dispose()}
    Show-CompletionCard $config.instances[0]
    Check ($script:completionCards.Count -eq 0) 'Direct official completion cannot create a card'
    Open-CompletionTarget $config.instances[0] ([guid]::NewGuid().ToString())
    Check ($script:opened.Count -eq 0 -and $script:taskLinks.Count -eq 0) 'Direct official notification navigation is rejected'
    Show-CompletionPreview
    $preview=$script:completionCards[0];$area=$script:completionArea
    Check ($preview.Bottom -eq $area.Bottom-20) 'API preview alone starts at bottom without an empty slot'
    Show-CompletionCard $config.instances[1]
    $api=$script:completionCards[0]
    Check ($api.Bottom -eq $area.Bottom-20 -and $preview.IsDisposed -and $script:completionCards.Count -eq 1) 'New notice replaces the prior card without stacking'
    $api.Controls['DismissNotice'].PerformClick()
    Check ($script:completionCards.Count -eq 0 -and $script:opened.Count -eq 0) 'Close icon dismisses the card without opening the task'
    Show-CompletionPreview
    Check ($script:completionCards.Count -eq 1 -and $preview.IsDisposed) 'Repeated preview replaces only the preview card'
    Show-CompletionCard $config.instances[1]
    $api=$script:completionCards[0]
    $script:openBusy=$true
    $api.Controls['NoticeBody'].PerformClick()
    Check (-not $api.IsDisposed -and $script:opened.Count -eq 0) 'Pending open preserves completion card for a later click'
    $script:openBusy=$false
    $api.Controls['NoticeBody'].PerformClick()
    Check ($script:opened.Count -eq 1 -and $script:opened[0] -eq $config.instances[1].id) 'API card button routes only to API instance'
    Show-CompletionPreview;$preview=$script:completionCards[0]
    $preview.Controls['NoticeBody'].PerformClick()
    Check ($script:opened.Count -eq 1) 'Preview closes without navigating any instance'
    Check ($script:completionCards.Count -eq 0) 'Open actions close their consumed cards'
    Save-CompletionSettings $config $script:completionSettings
    $inbox=Join-Path $script:completionRoot 'inbox';[void][IO.Directory]::CreateDirectory($inbox)
    $event=[ordered]@{schema=1;epoch=$script:completionSettings.epoch;instanceId=$config.instances[1].id;eventId=[Guid]::NewGuid().ToString('N');threadId=[Guid]::NewGuid().ToString();turnId=[Guid]::NewGuid().ToString()}
    Write-AtomicText (Join-Path $inbox 'valid.local.json') ($event|ConvertTo-Json)
    $event.epoch=[Guid]::NewGuid().ToString('N');Write-AtomicText (Join-Path $inbox 'stale.local.json') ($event|ConvertTo-Json)
    $event.epoch=$script:completionSettings.epoch;$event.instanceId='c'*32;Write-AtomicText (Join-Path $inbox 'unknown.local.json') ($event|ConvertTo-Json)
    $event.instanceId=$config.instances[0].id;$event.eventId=[Guid]::NewGuid().ToString('N');Write-AtomicText (Join-Path $inbox 'official.local.json') ($event|ConvertTo-Json)
    $SmokeTest=$false;Update-CompletionNotifications;$SmokeTest=$true
    Check ($script:completionCards.Count -eq 1 -and $script:completionCards[0].Tag -eq $config.instances[1].id) 'Queue admits only matching epoch and configured API instance'
    Check ($script:completionHistory.Count -eq 1 -and $script:completionHistory[0].instanceId -eq $config.instances[1].id) 'Same-epoch official event never enters notification history'
    Check (@(Get-ChildItem -LiteralPath $inbox).Count -eq 0) 'Consumed and rejected queue entries cannot replay'
    $savedThread=$script:completionCards[0].ThreadId
    $script:completionCards[0].Controls['NoticeBody'].PerformClick()
    Check ($script:taskLinks.Count -eq 1 -and $script:taskLinks[0].roles[0] -eq 'api' -and $script:taskLinks[0].threadId -eq $savedThread) 'Task click preserves instance role and exact thread ID'
    $apiHistory=@($script:completionHistory)
    $script:completionHistory=@([pscustomobject]@{instanceId=$config.instances[0].id;threadId=[guid]::NewGuid().ToString();title='official must be hidden'})+@($apiHistory)
    $filteredHistory=@(Get-ApiCompletionHistory)
    Check ($filteredHistory.Count -eq 1 -and $filteredHistory[0].instanceId -eq $config.instances[1].id) 'History filtering rejects legacy official records'
    $script:completionHistory=$apiHistory
    Set-CompletionSnooze 15
    Check ((Test-CompletionSnoozed) -and (Read-CompletionSettings $config).snoozedUntilUtc) 'Snooze persists its expiry'
    $event.instanceId=$config.instances[1].id;$event.eventId=[Guid]::NewGuid().ToString('N');$event.threadId=[Guid]::NewGuid().ToString()
    $event['title']='完成控制器界面更新';$event['utc']=[DateTime]::UtcNow.ToString('o')
    Write-AtomicText (Join-Path $inbox 'snoozed.local.json') ($event|ConvertTo-Json)
    $SmokeTest=$false;Update-CompletionNotifications;$SmokeTest=$true
    Check ($script:completionCards.Count -eq 0 -and $script:completionHistory.Count -eq 2) 'Snoozed completion enters recent history without popup'
    Set-CompletionSnooze 0
    Check (-not (Test-CompletionSnoozed)) 'Resume clears snooze immediately'
    Show-CompletionCard $config.instances[1] $event
    [Windows.Forms.Application]::DoEvents()
    Save-UiScreenshot $script:completionCards[0] (Join-Path $root 'notification.png')
    Check ($script:completionCards[0].Controls.Count -eq 3 -and $script:completionCards[0].Height -ge 100 -and $script:completionCards[0].Height -le 184) 'Compact notice fits content with only status, click surface and close icon'
    Check ($script:completionCards[0].FormBorderStyle -eq 'None' -and $script:completionCards[0].AutoDismissMilliseconds -eq 15000) 'Notification has integrated chrome and bounded auto-dismiss'
    Close-CompletionCards
    $event.threadId='../../not-a-task';$event.eventId=[Guid]::NewGuid().ToString('N')
    Write-AtomicText (Join-Path $inbox 'invalid-task.local.json') ($event|ConvertTo-Json)
    $SmokeTest=$false;Update-CompletionNotifications;$SmokeTest=$true
    Check ($script:completionCards.Count -eq 0 -and $script:completionHistory.Count -eq 2) 'Malformed task IDs never enter cards or history'
    Set-CompletionSnooze 15
    for($n=0;$n -lt 25;$n++){
        $event.threadId=[Guid]::NewGuid().ToString();$event.eventId=[Guid]::NewGuid().ToString('N')
        Write-AtomicText (Join-Path $inbox ($n.ToString('D2')+'.local.json')) ($event|ConvertTo-Json)
    }
    $SmokeTest=$false;Update-CompletionNotifications;$SmokeTest=$true
    Check ($script:completionHistory.Count -eq 20 -and $script:completionCards.Count -eq 0) 'Recent tasks stay bounded while snoozed'
    $script:completionSettings.snoozedUntilUtc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
    Check (-not (Test-CompletionSnoozed)) 'Expired snooze automatically permits new popups'
    $epoch=$script:completionSettings.epoch
    Set-CompletionNotificationsEnabled $false
    Check (-not (Read-CompletionSettings $config).enabled -and $script:completionCards.Count -eq 0) 'Disable persists and closes all independent cards'
    Set-CompletionNotificationsEnabled $true
    Check ((Read-CompletionSettings $config).enabled -and $script:completionSettings.epoch -ne $epoch) 'Re-enable uses fresh baseline epoch'
    $method=[CodexDual.CompletionCard].GetProperty('ShowWithoutActivation',[Reflection.BindingFlags]'Instance,NonPublic')
    $probe=New-Object CodexDual.CompletionCard
    try{Check ([bool]$method.GetValue($probe,$null)) 'Completion cards show without stealing focus'}finally{$probe.Dispose()}
    $expiring=New-Object CodexDual.CompletionCard;$expiring.StartPosition='Manual';$expiring.Location=New-Object Drawing.Point(-10000,-10000);$expiring.AutoDismissMilliseconds=150;$expiring.ShowInTaskbar=$false;$expiring.Show()
    $deadline=[DateTime]::UtcNow.AddSeconds(2)
    while(-not $expiring.IsDisposed -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    try{Check $expiring.IsDisposed 'Unattended notification actually dismisses through UI message loop'}finally{if(-not $expiring.IsDisposed){$expiring.Dispose()}}
    $paused=New-Object CodexDual.CompletionCard;$paused.StartPosition='Manual';$paused.Location=New-Object Drawing.Point(-10000,-10000);$paused.ShowInTaskbar=$false
    $paused.SetDisplaySettings(700,$false);$paused.PauseDismissal=$true;$paused.Show()
    $pauseUntil=[DateTime]::UtcNow.AddMilliseconds(1000)
    while([DateTime]::UtcNow -lt $pauseUntil){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    Check (-not $paused.IsDisposed) 'Active interaction suspends the dismissal countdown'
    $paused.PauseDismissal=$false
    $pauseUntil=[DateTime]::UtcNow.AddMilliseconds(350)
    while([DateTime]::UtcNow -lt $pauseUntil){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    Check (-not $paused.IsDisposed) 'Countdown resumes with its remaining time after interaction'
    $deadline=[DateTime]::UtcNow.AddSeconds(2)
    while(-not $paused.IsDisposed -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    try{Check $paused.IsDisposed 'Resumed countdown eventually dismisses card'}finally{if(-not $paused.IsDisposed){$paused.Dispose()}}
    # Simulate the attention boundary after the native identity checks in
    # Test-FastRestore; exercise actual queue consumption and UI creation here.
    function Test-CompletionForeground($Instance){return $script:foregroundApi}
    $script:foregroundApi=$true
    $script:completionHistory=@();Close-CompletionCards
    $event.threadId=[Guid]::NewGuid().ToString();$event.eventId=[Guid]::NewGuid().ToString('N')
    $event.epoch=$script:completionSettings.epoch
    Write-AtomicText (Join-Path $inbox 'foreground.local.json') ($event|ConvertTo-Json)
    $SmokeTest=$false;Update-CompletionNotifications;$SmokeTest=$true
    Check ($script:completionCards.Count -eq 0) 'Foreground API completion creates no popup'
    Check ($script:completionHistory.Count -eq 1) 'Suppressed completion remains in recent history'
    Check (-not (Test-Path (Join-Path $inbox 'foreground.local.json'))) 'Foreground completion is consumed rather than deferred'
    Show-CompletionPreview
    Check ($script:completionCards.Count -eq 1 -and $script:completionCards[0].Name -eq 'CompletionPreview') 'Explicit preview remains available in foreground'
    Close-CompletionCards;$script:foregroundApi=$false
    $SmokeTest=$false;Update-CompletionNotifications;$SmokeTest=$true
    Check ($script:completionCards.Count -eq 0) 'Switching away does not replay suppressed events'
    $event.eventId=[Guid]::NewGuid().ToString('N')
    Write-AtomicText (Join-Path $inbox 'background.local.json') ($event|ConvertTo-Json)
    $SmokeTest=$false;Update-CompletionNotifications;$SmokeTest=$true
    Check ($script:completionCards.Count -eq 1) 'New background completion still shows its popup'
}finally{Dispose-CompletionNotifications;$panel.Dispose()}
Write-Output "PASSED: $script:passed notification UI checks. Output: $root"
