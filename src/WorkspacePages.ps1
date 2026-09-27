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
    $note=New-UiLabel $script:notificationsPage '待回答的问题、完成提醒和最近记录，都在这里。' 1 59 580 28;$note.Name='Muted'
    $surface=New-Object CodexDual.Surface;$surface.SetBounds(0,102,608,143);$script:notificationsPage.Controls.Add($surface)
    $script:notificationEnabled=New-Object CodexDual.QuietSwitch;$script:notificationEnabled.Text='任务完成时显示提醒';$script:notificationEnabled.SetBounds(20,14,360,32);$surface.Controls.Add($script:notificationEnabled)
    $script:notificationEnabled.Add_Click({param($sender,$e) Invoke-NotificationUiAction @{action='toggle';enabled=$sender.Checked}})
    $script:notificationPreview=New-UiButton $surface '预览通知' 460 14 126 {Invoke-NotificationUiAction @{action='preview'}};$script:notificationPreview.Height=34
    $script:notificationStatus=New-UiLabel $surface '' 20 53 414 28;$script:notificationStatus.Name='Muted'
    $script:notificationDisplay=New-UiButton $surface '显示设置' 460 52 126 {Show-NotificationDisplaySettings};$script:notificationDisplay.Height=32
    $script:notificationPause15=New-UiButton $surface '暂停 15 分钟' 18 92 180 {Invoke-NotificationUiAction @{action='snooze';minutes=15}}
    $script:notificationPause60=New-UiButton $surface '暂停 1 小时' 214 92 180 {Invoke-NotificationUiAction @{action='snooze';minutes=60}}
    $script:notificationResume=New-UiButton $surface '恢复提醒' 410 92 178 {Invoke-NotificationUiAction @{action='snooze';minutes=0}}
    $script:notificationListMode='recent'
    $script:pendingTab=New-UiButton $script:notificationsPage '待处理' 0 257 132 {$script:notificationListMode='pending';$script:notificationHistoryPage=0;Update-NotificationView -Force};$script:pendingTab.Quiet=$true
    $script:recentTab=New-UiButton $script:notificationsPage '最近完成' 144 257 132 {$script:notificationListMode='recent';$script:notificationHistoryPage=0;Update-NotificationView -Force};$script:recentTab.Quiet=$true
    $script:questionConnect=New-UiButton $script:notificationsPage '连接提问' 348 257 120 {if(Get-Command Select-QuestionBridge -ErrorAction SilentlyContinue){Select-QuestionBridge}};$script:questionConnect.Quiet=$true
    $script:questionPreviewButton=New-UiButton $script:notificationsPage '预览提问' 480 257 128 {if(Get-Command Show-QuestionPreview -ErrorAction SilentlyContinue){Show-QuestionPreview}};$script:questionPreviewButton.Quiet=$true
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
    $script:notificationPreview.Enabled=$ready;$script:notificationDisplay.Enabled=$ready;$script:notificationPause15.Enabled=$enabled;$script:notificationPause60.Enabled=$enabled
    $script:notificationResume.Enabled=$enabled -and (Test-CompletionSnoozed)
    $script:notificationStatus.Text=if($ready){Get-CompletionStatusText}else{'通知暂不可用，请检查环境。'}
    $pending=if(Get-Command Get-PendingQuestionEntries -ErrorAction SilentlyContinue){@(Get-PendingQuestionEntries)}else{@()}
    $isPending=$script:notificationListMode -eq 'pending'
    $script:pendingTab.Text='待处理'+$(if(@($pending).Count){' ('+@($pending).Count+')'}else{''});$script:pendingTab.Selected=$isPending;$script:recentTab.Selected=-not $isPending
    $script:questionConnect.Visible=$isPending;$script:questionPreviewButton.Visible=$isPending;$script:clearNotificationHistory.Visible=-not $isPending
    $entries=@(if($isPending){$pending}else{$script:completionHistory});$pages=[Math]::Max(1,[int][Math]::Ceiling($entries.Count/2.0))
    $script:notificationHistoryPage=[Math]::Max(0,[Math]::Min($script:notificationHistoryPage,$pages-1))
    $script:historyPrevious.Visible=$entries.Count -gt 0;$script:historyNext.Visible=$entries.Count -gt 0;$script:historyPrevious.Enabled=$script:notificationHistoryPage -gt 0;$script:historyNext.Enabled=$script:notificationHistoryPage -lt $pages-1
    $script:historyCounter.Text=if($entries.Count){($script:notificationHistoryPage+1).ToString()+' / '+$pages+' · 共 '+$entries.Count+' 条'}elseif($isPending){if(Get-Variable questionStatus -Scope Script -ErrorAction SilentlyContinue){$script:questionStatus}else{'尚未连接提问服务'}}else{'保留本次运行的最近 20 条完成记录'}
    $script:clearNotificationHistory.Enabled=$entries.Count -gt 0
    $stamp=($script:notificationListMode+'|'+$script:notificationHistoryPage.ToString()+'|'+(($entries|ForEach-Object {([string](Get-ObjectValue $_ 'threadId' ''))+':'+([string](Get-ObjectValue $_ 'title' ''))+':'+([string](Get-ObjectValue $_ 'requestToken' ''))}) -join '|'))
    if(-not $Force -and $stamp -eq $script:notificationHistoryStamp){return};$script:notificationHistoryStamp=$stamp
    while($script:notificationHistoryBody.Controls.Count){$script:notificationHistoryBody.Controls[0].Dispose()}
    if(-not $entries.Count){$empty=New-UiLabel $script:notificationHistoryBody $(if($isPending){'暂时没有待处理的问题。提示收起后，可在这里继续回答。'}else{'任务完成后，记录会出现在这里。'}) 2 21 596 54;$empty.Name='Muted'}
    else{
        $y=0
        foreach($event in @($entries|Select-Object -Skip ($script:notificationHistoryPage*2) -First 2)){
            if($isPending){
                $row=New-Object CodexDual.QuickActionButton;$row.Text=([string]@($event.questions)[0].question -replace '[\p{Cc}\p{Cf}]',' ');$row.Detail='API · '+@($event.questions).Count+' 个问题 · 点击回答';$row.ActionIcon='bell';$row.SetBounds(0,$y,608,58);$row.Tag=[string]$event.requestToken
                $row.Add_Click({param($sender,$e) Show-PendingQuestion ([string]$sender.Tag)});$script:notificationHistoryBody.Controls.Add($row);$y+=62;continue
            }
            $instance=@($config.instances|Where-Object {$_.id -eq $event.instanceId});if($instance.Count -ne 1){continue}
            $row=New-Object CodexDual.QuickActionButton;$row.Text=([string](Get-ObjectValue $event 'title' '任务已完成') -replace '[\p{Cc}\p{Cf}]',' ');$row.ActionIcon='clock';$row.SetBounds(0,$y,608,58);$row.Tag=@{instance=$instance[0];threadId=$event.threadId}
            $row.Detail=Get-InstanceDisplayName $instance[0] $script:preferences
            $row.Add_Click({param($sender,$e) $target=$sender.Tag;Invoke-PanelAction {Open-CompletionTarget $target.instance $target.threadId}})
            $script:notificationHistoryBody.Controls.Add($row);$y+=62
        }
    }
    Set-UiTheme $script:notificationsPage
}
function Show-NotificationDisplaySettings {
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='通知显示设置';$dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false
    $dialog.StartPosition='CenterParent';$dialog.ShowInTaskbar=$false;$dialog.ClientSize=New-Object Drawing.Size(420,228);$dialog.Font=$panel.Font
    try{
        [void](New-UiLabel $dialog '自动关闭' 20 18 122 28)
        $choices=New-Object Windows.Forms.ComboBox;$choices.Name='DisplayDuration';$choices.DropDownStyle='DropDownList';$choices.SetBounds(150,16,244,30)
        [void]$choices.Items.AddRange([object[]]@('3 秒','5 秒','10 秒','15 秒','30 秒','自定义','常驻，手动关闭'))
        $dialog.Controls.Add($choices)
        $custom=New-Object Windows.Forms.NumericUpDown;$custom.Name='CustomSeconds';$custom.Minimum=1;$custom.Maximum=3600;$custom.Value=15;$custom.SetBounds(150,60,108,28);$dialog.Controls.Add($custom)
        $unit=New-UiLabel $dialog '秒 (1–3600)' 268 62 130 26;$unit.Name='Muted'
        $seconds=[int]$script:completionSettings.displaySeconds
        $index=(@(3,5,10,15,30).IndexOf($seconds))
        if($seconds -eq 0){$index=6}elseif($index -lt 0){$index=5;$custom.Value=$seconds}
        $choices.SelectedIndex=$index;$custom.Enabled=$index -eq 5
        $choices.Add_SelectedIndexChanged({$custom.Enabled=$choices.SelectedIndex -eq 5}.GetNewClosure())
        $animation=New-Object CodexDual.QuietSwitch;$animation.Name='FadeAnimation';$animation.Text='淡入淡出动画';$animation.Checked=[bool]$script:completionSettings.fadeEnabled
        $animation.SetBounds(20,110,360,32);$dialog.Controls.Add($animation)
        $cancel=New-UiButton $dialog '取消' 172 172 106 { $dialog.DialogResult=[Windows.Forms.DialogResult]::Cancel;$dialog.Close() }.GetNewClosure()
        $save=New-UiButton $dialog '保存' 290 172 106 {
            param($sender,$e)
            $owner=$sender.FindForm()
            $choices=$owner.Controls['DisplayDuration'];$custom=$owner.Controls['CustomSeconds'];$animation=$owner.Controls['FadeAnimation']
            try{
                $duration=if($choices.SelectedIndex -eq 6){0}elseif($choices.SelectedIndex -eq 5){[int]$custom.Value}else{@(3,5,10,15,30)[$choices.SelectedIndex]}
                Set-CompletionDisplaySettings $duration $animation.Checked
                $owner.DialogResult=[Windows.Forms.DialogResult]::OK;$owner.Close()
                Update-NotificationView -Force;Set-UiMessage '通知显示设置已保存。'
            }catch{Show-Error $_}
        };$save.Name='SaveDisplay';$save.Primary=$true
        $dialog.AcceptButton=$save
        $dialog.CancelButton=$cancel
        Set-UiTheme $dialog
        [void]$dialog.ShowDialog($panel)
    }finally{$dialog.Dispose()}
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
    if($changed -or $Force){foreach($root in $roots){Set-UiTheme $root;if($root -is [CodexDual.QuestionWindow]){$root.ApplyAppearance()};$root.Invalidate($true)}}
    Update-AppearanceControls
}
function Set-ControllerAppearance([ValidateSet('dark','light','system')][string]$Mode,[ValidateSet('neutral','blue','green','purple')][string]$Accent) {
    $saved=Read-ControllerPreferences $config
    if($Mode){$saved.appearance.mode=$Mode};if($Accent){$saved.appearance.accent=$Accent}
    Save-ControllerPreferences $config $saved;$script:preferences=$saved
    Update-ControllerAppearance -Force
    Set-UiMessage '外观已保存，即时生效。'
}
