# Application pages and shared commands. Page navigation never opens an unrelated settings surface.
function Initialize-PreferencesPage($Parent) {
    $script:settingsPage=New-Object Windows.Forms.Panel;$script:settingsPage.SetBounds(208,18,608,462);$script:settingsPage.Visible=$false;$Parent.Controls.Add($script:settingsPage)
    $script:settingsHeading=New-UiLabel $script:settingsPage '偏好设置' 0 0 560 52;$script:settingsHeading.Font=New-Object Drawing.Font($Parent.Font.FontFamily,20,[Drawing.FontStyle]::Bold)
    $note=New-UiLabel $script:settingsPage '外观即时生效，并在下次打开时保留。' 1 59 580 28;$note.Name='Muted'
    $appearance=New-Object CodexDual.Surface;$appearance.SetBounds(0,102,608,210);$script:settingsPage.Controls.Add($appearance)
    [void](New-UiLabel $appearance '颜色模式' 20 14 560 26)
    $script:themeButtons=@{};$x=18
    foreach($entry in @(@('dark','深色'),@('light','浅色'),@('system','跟随系统'))){
        $button=New-UiButton $appearance $entry[1] $x 50 180 {param($sender,$e) try{Set-ControllerAppearance -Mode $sender.Tag}catch{Show-Error $_}};$button.Tag=$entry[0];$button.Height=38;$script:themeButtons[$entry[0]]=$button;$x+=195
    }
    [void](New-UiLabel $appearance '强调色' 20 112 560 26)
    $script:accentButtons=@{};$x=18
    foreach($entry in @(@('neutral','中性'),@('blue','蓝色'),@('green','绿色'),@('purple','紫色'))){
        $button=New-UiButton $appearance $entry[1] $x 148 133 {param($sender,$e) try{Set-ControllerAppearance -Accent $sender.Tag}catch{Show-Error $_}};$button.Tag=$entry[0];$button.Height=38;$script:accentButtons[$entry[0]]=$button;$x+=145
    }
    $startupArea=New-Object CodexDual.Surface;$startupArea.SetBounds(0,328,608,124);$script:settingsPage.Controls.Add($startupArea)
    $startup=New-Object CodexDual.QuietSwitch;$startup.Text='登录时打开控制面板';$startup.SetBounds(20,14,555,32);$startupArea.Controls.Add($startup)
    $script:startupToggle=$startup;$toolRoot=Split-Path $PSScriptRoot -Parent
    $startup.Checked=[bool](Repair-ControllerAutoStart $toolRoot $ConfigPath)
    $startup.Add_Click({param($sender,$e)
        $root=Split-Path $PSScriptRoot -Parent
        try{Set-ControllerAutoStart $root $ConfigPath $sender.Checked;Set-UiMessage $(if($sender.Checked){'已开启登录时显示控制面板。'}else{'已关闭登录时显示控制面板。'})}
        catch{$sender.Checked=[bool](Test-ControllerAutoStart $root $ConfigPath);Show-Error $_}
    })
    $hint=New-UiLabel $startupArea ('托盘：单击打开 API，双击打开面板。'+"`r`n"+'单击判定 '+$trayClick.Interval+' 毫秒，右键打开快捷面板。') 20 59 563 54;$hint.Name='Muted';$hint.Font=New-Object Drawing.Font($Parent.Font.FontFamily,8.5)
}
function Initialize-NotificationsPage($Parent) {
    $script:notificationsPage=New-Object Windows.Forms.Panel;$script:notificationsPage.SetBounds(208,18,608,462);$script:notificationsPage.Visible=$false;$Parent.Controls.Add($script:notificationsPage)
    $title=New-UiLabel $script:notificationsPage '通知' 0 0 580 52;$title.Font=New-Object Drawing.Font($Parent.Font.FontFamily,20,[Drawing.FontStyle]::Bold)
    $note=New-UiLabel $script:notificationsPage '完成提醒、暂停和最近记录，都在这里管理。' 1 59 580 28;$note.Name='Muted'
    $surface=New-Object CodexDual.Surface;$surface.SetBounds(0,102,608,143);$script:notificationsPage.Controls.Add($surface)
    $script:notificationEnabled=New-Object CodexDual.QuietSwitch;$script:notificationEnabled.Text='任务完成时显示提醒';$script:notificationEnabled.SetBounds(20,14,360,32);$surface.Controls.Add($script:notificationEnabled)
    $script:notificationEnabled.Add_Click({param($sender,$e) Invoke-NotificationUiAction @{action='toggle';enabled=$sender.Checked}})
    $script:notificationPreview=New-UiButton $surface '预览通知' 460 14 126 {Invoke-NotificationUiAction @{action='preview'}};$script:notificationPreview.Height=34
    $script:notificationStatus=New-UiLabel $surface '' 20 53 562 28;$script:notificationStatus.Name='Muted'
    $script:notificationPause15=New-UiButton $surface '暂停 15 分钟' 18 92 180 {Invoke-NotificationUiAction @{action='snooze';minutes=15}}
    $script:notificationPause60=New-UiButton $surface '暂停 1 小时' 214 92 180 {Invoke-NotificationUiAction @{action='snooze';minutes=60}}
    $script:notificationResume=New-UiButton $surface '恢复提醒' 410 92 178 {Invoke-NotificationUiAction @{action='snooze';minutes=0}}
    [void](New-UiLabel $script:notificationsPage '最近完成' 0 261 340 28)
    $script:clearNotificationHistory=New-UiButton $script:notificationsPage '清除记录' 480 257 128 {Invoke-NotificationUiAction @{action='clear'}};$script:clearNotificationHistory.Quiet=$true
    $script:notificationHistoryBody=New-Object Windows.Forms.Panel;$script:notificationHistoryBody.SetBounds(0,297,608,122);$script:notificationsPage.Controls.Add($script:notificationHistoryBody)
    $script:notificationHistoryPage=0;$script:notificationHistoryStamp=''
    $script:historyPrevious=New-UiButton $script:notificationsPage '上一页' 0 425 100 {$script:notificationHistoryPage--;Update-NotificationView -Force}
    $script:historyCounter=New-UiLabel $script:notificationsPage '' 110 430 380 24;$script:historyCounter.TextAlign='MiddleCenter';$script:historyCounter.Name='Muted'
    $script:historyNext=New-UiButton $script:notificationsPage '下一页' 508 425 100 {$script:notificationHistoryPage++;Update-NotificationView -Force}
}
function Update-NotificationView([switch]$Force) {
    if(-not (Get-Variable notificationsPage -Scope Script -ErrorAction SilentlyContinue)){return}
    $ready=$script:completionReady
    $enabled=$ready -and $script:completionSettings.enabled
    $script:notificationEnabled.Enabled=$ready;$script:notificationEnabled.Checked=$enabled
    $script:notificationPreview.Enabled=$ready;$script:notificationPause15.Enabled=$enabled;$script:notificationPause60.Enabled=$enabled
    $script:notificationResume.Enabled=$enabled -and (Test-CompletionSnoozed)
    $script:notificationStatus.Text=if($ready){Get-CompletionStatusText}else{'通知暂不可用，请检查环境。'}
    $entries=@($script:completionHistory);$pages=[Math]::Max(1,[int][Math]::Ceiling($entries.Count/2.0))
    $script:notificationHistoryPage=[Math]::Max(0,[Math]::Min($script:notificationHistoryPage,$pages-1))
    $script:historyPrevious.Visible=$entries.Count -gt 0;$script:historyNext.Visible=$entries.Count -gt 0;$script:historyPrevious.Enabled=$script:notificationHistoryPage -gt 0;$script:historyNext.Enabled=$script:notificationHistoryPage -lt $pages-1
    $script:historyCounter.Text=if($entries.Count){($script:notificationHistoryPage+1).ToString()+' / '+$pages+' · 共 '+$entries.Count+' 条'}else{'保留本次运行的最近 20 条完成记录'}
    $script:clearNotificationHistory.Enabled=$entries.Count -gt 0
    $stamp=($script:notificationHistoryPage.ToString()+'|'+(($entries|ForEach-Object {([string](Get-ObjectValue $_ 'threadId' ''))+':'+([string](Get-ObjectValue $_ 'title' ''))}) -join '|'))
    if(-not $Force -and $stamp -eq $script:notificationHistoryStamp){return};$script:notificationHistoryStamp=$stamp
    while($script:notificationHistoryBody.Controls.Count){$script:notificationHistoryBody.Controls[0].Dispose()}
    if(-not $entries.Count){$empty=New-UiLabel $script:notificationHistoryBody '任务完成后，记录会出现在这里。' 2 21 596 54;$empty.Name='Muted'}
    else{
        $y=0
        foreach($event in @($entries|Select-Object -Skip ($script:notificationHistoryPage*2) -First 2)){
            $instance=@($config.instances|Where-Object {$_.id -eq $event.instanceId});if($instance.Count -ne 1){continue}
            $row=New-Object CodexDual.QuickActionButton;$row.Text=([string](Get-ObjectValue $event 'title' '任务已完成') -replace '[\p{Cc}\p{Cf}]',' ');$row.ActionIcon='clock';$row.SetBounds(0,$y,608,58);$row.Tag=@{instance=$instance[0];threadId=$event.threadId}
            $row.Detail=Get-InstanceDisplayName $instance[0] $script:preferences
            $row.Add_Click({param($sender,$e) $target=$sender.Tag;Invoke-PanelAction {Open-CompletionTarget $target.instance $target.threadId}})
            $script:notificationHistoryBody.Controls.Add($row);$y+=62
        }
    }
    Set-UiTheme $script:notificationsPage
}
function Invoke-NotificationUiAction([hashtable]$Command) {
    try{
        switch($Command.action){
            'toggle' {Set-CompletionNotificationsEnabled ([bool]$Command.enabled)}
            'snooze' {Set-CompletionSnooze ([int]$Command.minutes)}
            'dismiss' {Close-CompletionCards}
            'clear' {$script:completionHistory=@()}
            'preview' {Show-CompletionPreview}
        }
        if(Get-Variable completionMenu -ErrorAction SilentlyContinue){$completionMenu.Checked=$script:completionSettings.enabled}
        Update-NotificationView -Force
        if((Get-Variable quickPopup -Scope Script -ErrorAction SilentlyContinue) -and $script:quickPopup -and $script:quickPopup.Visible){Set-QuickPopupPage $script:quickPopupPage -Refresh}
    }catch{Set-UiMessage $_.Exception.Message;Update-NotificationView;Show-Error $_}
}
function Mark-ThemeSemantics($Root) {
    foreach($control in $Root.Controls){if($control -is [Windows.Forms.Label] -and -not $control.Name -and $control.ForeColor.ToArgb() -eq [CodexDual.AppTheme]::Muted.ToArgb()){$control.Name='Muted'};if($control.HasChildren){Mark-ThemeSemantics $control}}
}
function Update-AppearanceControls {
    if(Get-Variable themeButtons -Scope Script -ErrorAction SilentlyContinue){foreach($key in $script:themeButtons.Keys){$script:themeButtons[$key].Selected=$key -eq $script:preferences.appearance.mode;$script:themeButtons[$key].Invalidate()};foreach($key in $script:accentButtons.Keys){$script:accentButtons[$key].Selected=$key -eq $script:preferences.appearance.accent;$script:accentButtons[$key].Primary=$script:accentButtons[$key].Selected;$script:accentButtons[$key].Invalidate()}}
}
function Update-ControllerAppearance([switch]$Force) {
    $roots=@([Windows.Forms.Application]::OpenForms);if($panel -and $panel -notin $roots){$roots+=,$panel}
    if((Get-Variable quickPopup -Scope Script -ErrorAction SilentlyContinue) -and $script:quickPopup -and $script:quickPopup -notin $roots){$roots+=,$script:quickPopup}
    foreach($root in $roots){Mark-ThemeSemantics $root}
    $changed=[CodexDual.AppTheme]::SetAppearance($script:preferences.appearance.mode,$script:preferences.appearance.accent)
    if($changed -or $Force){foreach($root in $roots){Set-UiTheme $root;$root.Invalidate($true)}}
    Update-AppearanceControls
}
function Set-ControllerAppearance([ValidateSet('dark','light','system')][string]$Mode,[ValidateSet('neutral','blue','green','purple')][string]$Accent) {
    $saved=Read-ControllerPreferences $config
    if($Mode){$saved.appearance.mode=$Mode};if($Accent){$saved.appearance.accent=$Accent}
    Save-ControllerPreferences $config $saved;$script:preferences=$saved
    Update-ControllerAppearance -Force
    Set-UiMessage '外观已保存，即时生效。'
}
