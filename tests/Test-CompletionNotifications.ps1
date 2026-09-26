$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\..\src\Panel.ps1"
. "$PSScriptRoot\..\src\CompletionNotifications.ps1"
$script:passed=0
function Check($Value,$Message){if(-not $Value){throw ('FAIL: '+$Message)};$script:passed++;Write-Output ('PASS: '+$Message)}
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
function Start-PanelOpen([string[]]$Roles,[string]$ThreadId){$script:taskLinks+=@{roles=$Roles;threadId=$ThreadId}}
try{
    Initialize-CompletionNotifications
    Check ($null -eq $script:completionWorker) 'Smoke mode creates no worker process'
    Show-CompletionCard $config.instances[0]
    $official=$script:completionCards[0];$area=$script:completionArea
    Check ($official.Bottom -eq $area.Bottom-20) 'Official alone starts at bottom without an empty API slot'
    Show-CompletionCard $config.instances[1]
    $api=$script:completionCards[1]
    Check ($api.Bottom -eq $area.Bottom-20 -and $official.Bottom -eq $api.Top-12) 'New card takes bottom and existing card stacks immediately above'
    $api.Close()
    Check ($official.Bottom -eq $area.Bottom-20) 'Closing bottom card removes the empty slot'
    Show-CompletionCard $config.instances[0]
    Check ($script:completionCards.Count -eq 1 -and $official.IsDisposed) 'Repeated completion replaces only the same environment card'
    Show-CompletionCard $config.instances[1]
    $api=$script:completionCards[1]
    $script:openBusy=$true
    @($api.Controls|Where-Object {$_.Text -eq '打开对应端'})[0].PerformClick()
    Check (-not $api.IsDisposed -and $script:opened.Count -eq 0) 'Pending open preserves completion card for a later click'
    $script:openBusy=$false
    @($api.Controls|Where-Object {$_.Text -eq '打开对应端'})[0].PerformClick()
    Check ($script:opened.Count -eq 1 -and $script:opened[0] -eq $config.instances[1].id) 'API card button routes only to API instance'
    $official=$script:completionCards[0]
    @($official.Controls|Where-Object {$_.Text -eq '打开对应端'})[0].PerformClick()
    Check ($script:opened.Count -eq 2 -and $script:opened[1] -eq $config.instances[0].id) 'Official card button routes only to official instance'
    Check ($script:completionCards.Count -eq 0) 'Open actions close their consumed cards'
    Save-CompletionSettings $config $script:completionSettings
    $inbox=Join-Path $script:completionRoot 'inbox';[void][IO.Directory]::CreateDirectory($inbox)
    $event=[ordered]@{schema=1;epoch=$script:completionSettings.epoch;instanceId=$config.instances[1].id;eventId=[Guid]::NewGuid().ToString('N');threadId=[Guid]::NewGuid().ToString();turnId=[Guid]::NewGuid().ToString()}
    Write-AtomicText (Join-Path $inbox 'valid.local.json') ($event|ConvertTo-Json)
    $event.epoch=[Guid]::NewGuid().ToString('N');Write-AtomicText (Join-Path $inbox 'stale.local.json') ($event|ConvertTo-Json)
    $event.epoch=$script:completionSettings.epoch;$event.instanceId='c'*32;Write-AtomicText (Join-Path $inbox 'unknown.local.json') ($event|ConvertTo-Json)
    $SmokeTest=$false;Update-CompletionNotifications;$SmokeTest=$true
    Check ($script:completionCards.Count -eq 1 -and $script:completionCards[0].Tag -eq $config.instances[1].id) 'Queue admits only matching epoch and configured instance'
    Check (@(Get-ChildItem -LiteralPath $inbox).Count -eq 0) 'Consumed and rejected queue entries cannot replay'
    $savedThread=$script:completionCards[0].ThreadId
    @($script:completionCards[0].Controls|Where-Object {$_.Text -eq '查看任务'})[0].PerformClick()
    Check ($script:taskLinks.Count -eq 1 -and $script:taskLinks[0].roles[0] -eq 'api' -and $script:taskLinks[0].threadId -eq $savedThread) 'Task click preserves instance role and exact thread ID'
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
}finally{Dispose-CompletionNotifications;$panel.Dispose()}
Write-Output "PASSED: $script:passed notification UI checks. Output: $root"
