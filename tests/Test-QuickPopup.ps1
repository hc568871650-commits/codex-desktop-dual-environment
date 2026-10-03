$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\..\src\Panel.ps1"
. "$PSScriptRoot\..\src\CompletionNotifications.ps1"
. "$PSScriptRoot\..\src\QuickPopup.ps1"
. "$PSScriptRoot\..\src\WorkspacePages.ps1"
$script:passed=0;$script:calls=New-Object 'Collections.Generic.List[string]'
function Check($condition,$message){if(-not $condition){throw "FAIL: $message"};$script:passed++;Write-Output "PASS: $message"}
function Record($value){if($script:quickPopup.Visible){throw 'Command ran before popup closed'};[void]$script:calls.Add($value)}
function Invoke-PanelAction([scriptblock]$Action){& $Action}
function Open-PanelInstance($i){Record ('open:'+ $i.role)}
function Open-InstanceDirectory($i,$kind){Record ('directory:'+$i.role+':'+$kind)}
function Open-CompletionTarget($i,$thread){Record ('task:'+$i.role+':'+$thread)}
function Show-ControlPanel {Record 'panel'}
function Show-WorkspacePage($page){Record ('page:'+$page)}
function Set-CompletionSnooze($minutes){[void]$script:calls.Add(('snooze:'+$minutes));$script:completionSettings.snoozedUntilUtc=if($minutes){[DateTimeOffset]::UtcNow.AddMinutes($minutes).ToString('o')}else{''}}
function Get-CompletionStatusText {if(Test-CompletionSnoozed){return '已暂停'}else{return '已开启'}}
function Close-CompletionCards {Record 'dismiss'}
function Show-Error($e){throw $e}
function Set-UiMessage($message){throw $message}
# Rendering must not call these I/O boundaries, even when status is missing or stale.
function Get-InstanceStatus {throw 'Popup rendering performed process I/O'}
function Read-ControllerPreferences {throw 'Popup rendering performed disk I/O'}
$config=[pscustomobject]@{instances=@([pscustomobject]@{id=('a'*32);role='official'},[pscustomobject]@{id=('b'*32);role='api'})}
$script:preferences=@{names=@{}};$script:uiBusy=$false;$script:openBusy=$false;$script:statusCache=@{}
$script:completionReady=$true;$script:completionSettings=[pscustomobject]@{enabled=$true;snoozedUntilUtc=''};$script:completionHistory=@()
$panel=New-Object Windows.Forms.Form;$panel.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5)
$anchor=New-Object Drawing.Point(100,100)
function Row($action){return @($script:quickBody.Controls|Where-Object {$_.Tag -and $_.Tag.action -eq $action})[0]}
try{
    Initialize-QuickPopup
    Show-QuickPopup $anchor
    [Windows.Forms.Application]::DoEvents()
    Check ($script:quickPopup.Visible -and $script:quickBody.Controls.Count -eq 7) 'Home shows two environments and bounded quick actions without I/O'
    $handle=$script:quickPopup.Handle;$bounds=$script:quickPopup.Bounds
    Check ($script:quickPopupRows.api.Focused) 'Opening focuses the first available action'
    $script:quickPopupRows.api.PerformClick()
    Check ($script:calls.Count -eq 1 -and $script:calls[0] -eq 'open:api') 'API row closes popup then routes only to API'
    Show-QuickPopup $anchor
    $script:quickPopupRows.official.PerformClick()
    Check ($script:calls[1] -eq 'open:official') 'Official row preserves independent target'
    Show-QuickPopup $anchor
    Invoke-QuickPopupCommand @{action='page';page='directories'}
    Check ($script:quickPopup.Visible -and $script:quickPopup.Handle -eq $handle -and $script:quickPopup.Bounds -eq $bounds) 'Page navigation reuses the same window at the same position'
    Invoke-QuickPopupCommand @{action='folders';role='api'}
    $directory=@($script:quickBody.Controls|Where-Object {$_.Tag.kind -eq 'projectless'})[0]
    $directory.PerformClick()
    Check ($script:calls[2] -eq 'directory:api:projectless') 'Directory row retains environment and directory kind'
    $thread=[Guid]::NewGuid().ToString()
    $script:completionHistory=@([pscustomobject]@{instanceId=('b'*32);threadId=$thread;title="任务`n标题"})
    $script:completionHistory+=@([pscustomobject]@{instanceId=('a'*32);threadId=[guid]::NewGuid().ToString();title='官方记录不得展示'})
    Show-QuickPopup $anchor 'recent'
    Check (@($script:quickBody.Controls|Where-Object {$_.Tag -and $_.Tag.action -eq 'task'}).Count -eq 1 -and $script:quickSubtitle.Text -like '*1 条*') 'Recent popup filters official records before counting and pagination'
    $script:notificationListMode='history';$script:notificationHistoryPage=0
    Initialize-NotificationsPage $panel;Update-NotificationView -Force
    Check (@($script:notificationHistoryBody.Controls|Where-Object {$_ -is [CodexDual.QuickActionButton]}).Count -eq 1 -and -not @($script:notificationHistoryBody.Controls|Where-Object {$_.Text -eq '官方记录不得展示'}).Count) 'Notifications page only renders API history'
    $task=Row 'task';Check (-not $task.Text.Contains("`n")) 'Recent task titles remove control characters'
    $task.PerformClick()
    Check ($script:calls[3] -eq ('task:api:'+$thread)) 'Recent row preserves the exact task and environment'
    Show-QuickPopup $anchor 'notifications'
    Check ($script:quickPopup.Height -eq 260 -and @($script:quickBody.Controls).Count -eq 3) 'Notification shortcuts fit a compact page with three entries'
    (Row 'notification-settings').PerformClick()
    Check ($script:calls[4] -eq 'panel' -and $script:calls[5] -eq 'page:notifications' -and -not $script:quickPopup.Visible) 'Notification settings open only in the controller console'
    Show-QuickPopup $anchor 'notifications'
    Invoke-QuickPopupCommand @{action='page';page='recent'};Go-QuickPopupBack
    Check ($script:quickPopupPage -eq 'notifications') 'Back from notification history returns to notifications'
    Show-QuickPopup $anchor 'home'
    $script:openBusy=$true;Refresh-QuickPopupState
    Check (-not $script:quickPopupRows.api.Enabled -and -not $script:quickPopupRows.official.Enabled) 'Busy disables duplicate launches'
    $count=$script:calls.Count;Invoke-QuickPopupCommand @{action='open';role='api'}
    Check ($script:calls.Count -eq $count -and $script:quickPopup.Visible) 'Busy command guard rejects stale action without hiding navigation'
    (Row 'panel').PerformClick()
    Check ($script:calls[$script:calls.Count-1] -eq 'panel') 'Panel remains reachable while opening is busy'
    $script:openBusy=$false;$script:statusCache.api=[pscustomobject]@{State='Running'}
    Show-QuickPopup $anchor
    Check ($script:quickPopupRows.api.Detail -match '已运行') 'Cached running status renders without a new process query'
    for($i=0;$i -lt 30;$i++){Show-QuickPopup $anchor;Set-QuickPopupPage 'notifications';$script:quickPopup.Hide()}
    Check ($script:quickPopup.Handle -eq $handle -and [Windows.Forms.Application]::OpenForms.Count -eq 1) 'Repeated open and navigation keeps a single popup window'
    $script:completionHistory=@(1..20|ForEach-Object {[pscustomobject]@{instanceId=('b'*32);threadId=[Guid]::NewGuid().ToString();title=('完成记录 '+$_)}})
    Show-QuickPopup $anchor 'recent';[Windows.Forms.Application]::DoEvents()
    Check (-not $script:quickBody.VerticalScroll.Visible -and $script:quickPopup.Size.Height -eq 510 -and @($script:quickBody.Controls|Where-Object {$_.Tag -and $_.Tag.action -eq 'task'}).Count -eq 4) 'Long history stays bounded to four rows per page without a native scrollbar'
    Invoke-QuickPopupCommand @{action='recent-next'}
    Check ($script:quickRecentPage -eq 1 -and (Row 'task').Text -eq '完成记录 5' -and $script:quickPopup.Handle -eq $handle) 'Next page keeps position and reaches older records'
    Refresh-QuickPopupState
    Invoke-QuickPopupCommand @{action='recent-prev'}
    Check ($script:quickRecentPage -eq 0 -and (Row 'task').Text -eq '完成记录 1') 'Previous page returns without losing cached history'
    $script:completionReady=$false
    Show-QuickPopup $anchor 'notifications';Refresh-QuickPopupState
    Check ((Row 'notification-settings').Enabled -and $script:quickPopup.Visible) 'Unavailable notifications retain the console settings entry'
    $script:completionReady=$true
    $out=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('quick-popup-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($out)
    foreach($page in @('home','notifications','recent','more','appearance')){Show-QuickPopup $anchor $page;[Windows.Forms.Application]::DoEvents();Save-UiScreenshot $script:quickPopup (Join-Path $out ($page+'.png'))}
    Write-Output ('Screenshots: '+$out)
}finally{if($script:quickPopup){$script:quickPopup.Dispose()};$panel.Dispose()}
Write-Output "PASSED: $script:passed popup integration checks"
