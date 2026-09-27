# One reusable tray popup. Its view reads only cached UI state; actions use the existing controller boundaries.
if(-not ('CodexDual.TrayPopup' -as [type])){Add-Type -Path "$PSScriptRoot\TrayPopup.cs" -ReferencedAssemblies System.Windows.Forms,System.Drawing}
function Initialize-QuickPopup {
    $script:quickPopup=New-Object CodexDual.TrayPopup
    $script:quickPopup.Text='Codex 快捷操作';$script:quickPopup.ClientSize=New-Object Drawing.Size(360,510)
    $script:quickPopup.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5)
    $script:quickPopup.BackColor=[CodexDual.AppTheme]::Surface;$script:quickPopup.ForeColor=[CodexDual.AppTheme]::Text
    $script:quickBack=New-UiButton $script:quickPopup '‹' 12 16 36 {Go-QuickPopupBack};$script:quickBack.Quiet=$true;$script:quickBack.AccessibleName='返回快捷操作'
    $script:quickTitle=New-UiLabel $script:quickPopup 'Codex' 22 12 260 35;$script:quickTitle.Font=New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold)
    $script:quickSubtitle=New-UiLabel $script:quickPopup '快捷操作' 24 48 290 22;$script:quickSubtitle.Name='Muted';$script:quickSubtitle.ForeColor=[CodexDual.AppTheme]::Muted;$script:quickSubtitle.Font=New-Object Drawing.Font($panel.Font.FontFamily,8.5)
    $dismiss=New-UiButton $script:quickPopup '×' 310 16 34 { $script:quickPopup.Hide() };$dismiss.Quiet=$true;$dismiss.AccessibleName='关闭快捷操作';$dismiss.Anchor='Top,Right'
    $script:quickBody=New-Object Windows.Forms.Panel;$script:quickBody.SetBounds(12,82,336,382);$script:quickBody.Anchor='Top,Bottom,Left,Right';$script:quickBody.AutoScroll=$true;$script:quickPopup.Controls.Add($script:quickBody)
    $foot=New-UiLabel $script:quickPopup '单击托盘打开 API · 双击打开面板' 24 478 312 22;$foot.Name='Muted';$foot.ForeColor=[CodexDual.AppTheme]::Muted;$foot.Font=New-Object Drawing.Font($panel.Font.FontFamily,8);$foot.Anchor='Bottom,Left,Right'
    $script:quickNavigation=New-Object 'Collections.Generic.List[string]';$script:quickNotificationStamp='';$script:quickRecentPage=0;$script:quickPopupPage='home';$script:quickPopupRows=@{};$script:quickPopupRole='api'
}
function Add-QuickPopupRow([string]$Text,[string]$Detail,[hashtable]$Action,[int]$Y,[bool]$Enabled=$true,[string]$Icon='arrow') {
    $row=New-Object CodexDual.QuickActionButton;$row.Text=$Text;$row.Detail=$Detail;$row.ActionIcon=$Icon
    $row.SetBounds(0,$Y,316,$(if($Detail){62}else{42}));$row.Anchor='Top,Left,Right';$row.Tag=$Action;$row.Enabled=$Enabled
    $row.Add_Click({param($sender,$e) Invoke-QuickPopupCommand $sender.Tag})
    $script:quickBody.Controls.Add($row);return $row
}
function Get-QuickPopupStatus([string]$Role) {
    if($script:openBusy){return '正在处理窗口操作…'}
    $s=$script:statusCache[$Role]
    if(-not $s){return '状态待刷新 · 点击启动或找回'}
    switch($s.State){'Running'{'已运行 · 点击找回窗口'};'Stopped'{'未启动 · 点击打开'};default{'状态未知 · 点击检查并打开'}}
}
function Set-QuickPopupPage([ValidateSet('home','notifications','recent','directories','folders','more','appearance')][string]$Page,[switch]$Refresh) {
    if(-not $Refresh -and $Page -ne $script:quickPopupPage){$script:quickNavigation.Add($script:quickPopupPage)}
    $script:quickPopupPage=$Page;$script:quickPopupRows=@{}
    $script:quickBody.SuspendLayout()
    try{
        while($script:quickBody.Controls.Count){$script:quickBody.Controls[0].Dispose()}
        $script:quickBody.AutoScrollPosition=New-Object Drawing.Point(0,0)
        $script:quickBack.Visible=$Page -ne 'home';$script:quickTitle.Left=if($Page -eq 'home'){22}else{58}
        $script:quickTitle.Text=switch($Page){'home'{'Codex'};'notifications'{'通知'};'recent'{'最近完成'};'directories'{'环境目录'};'folders'{'常用目录'};'more'{'更多操作'};'appearance'{'外观'}}
        $script:quickSubtitle.Text=if($script:openBusy){'窗口操作进行中，仍可浏览或关闭'}else{'快捷操作'}
        $available=-not ($script:uiBusy -or $script:openBusy)
        switch($Page){
            'home' {
                $y=0
                foreach($role in @('api','official')){
                    $instance=@($config.instances|Where-Object {$_.role -eq $role})[0]
                    $script:quickPopupRows[$role]=Add-QuickPopupRow (Get-InstanceDisplayName $instance $script:preferences) (Get-QuickPopupStatus $role) @{action='open';role=$role} $y $available 'window';$y+=70
                }
                [void](Add-QuickPopupRow '打开控制面板' '' @{action='panel'} 152 $true 'panel')
                [void](Add-QuickPopupRow '通知' '' @{action='page';page='notifications'} 198 $true 'bell')
                [void](Add-QuickPopupRow '最近完成' '' @{action='page';page='recent'} 244 $true 'clock')
                [void](Add-QuickPopupRow '环境目录' '' @{action='page';page='directories'} 290 $true 'folder')
                [void](Add-QuickPopupRow '更多操作' '' @{action='page';page='more'} 336 $true 'more')
            }
            'notifications' {
                $enabled=$script:completionReady -and $script:completionSettings.enabled
                $script:quickSubtitle.Text=if($script:completionReady){Get-CompletionStatusText}else{'通知暂不可用'}
                $script:quickNotificationStamp=$script:quickSubtitle.Text+'|'+$enabled
                [void](Add-QuickPopupRow $(if($enabled){'完成提醒：已开启'}else{'完成提醒：已关闭'}) $(if($enabled){'点击关闭完成提醒'}else{'点击开启完成提醒'}) @{action='notification-toggle'} 0 $script:completionReady 'bell')
                [void](Add-QuickPopupRow '暂停提醒 15 分钟' '' @{action='snooze';minutes=15} 72 $enabled 'clock')
                [void](Add-QuickPopupRow '暂停提醒 1 小时' '' @{action='snooze';minutes=60} 120 $enabled 'clock')
                [void](Add-QuickPopupRow '恢复提醒' '' @{action='snooze';minutes=0} 168 ($enabled -and (Test-CompletionSnoozed)) 'bell')
                [void](Add-QuickPopupRow '预览通知' '' @{action='notification-preview'} 220 $script:completionReady 'panel')
                [void](Add-QuickPopupRow '关闭所有提示' '' @{action='dismiss'} 268 $script:completionReady 'close')
                [void](Add-QuickPopupRow '最近完成' '' @{action='page';page='recent'} 324 $true 'clock')
            }
            'appearance' {
                $script:quickSubtitle.Text='即时生效，自动保存'
                $y=0
                foreach($entry in @(@('dark','深色'),@('light','浅色'),@('system','跟随系统'))){$row=Add-QuickPopupRow $entry[1] '' @{action='appearance-mode';value=$entry[0]} $y $true 'settings';if([CodexDual.AppTheme]::Mode -eq $entry[0]){$row.Text+='  ✓'};$y+=48}
                $label=New-UiLabel $script:quickBody '强调色' 12 164 302 26;$label.Name='Muted'
                $i=0
                foreach($entry in @(@('neutral','中性'),@('blue','蓝色'),@('green','绿色'),@('purple','紫色'))){
                    $x=if($i%2 -eq 0){0}else{166};$y=202+[int][Math]::Floor($i/2)*48
                    $button=New-UiButton $script:quickBody $entry[1] $x $y 150 {param($sender,$e) Invoke-QuickPopupCommand @{action='appearance-accent';value=$sender.Tag}};$button.Tag=$entry[0];$button.Selected=[CodexDual.AppTheme]::Accent -eq $entry[0];$button.Primary=$button.Selected;$button.Height=38;$i++
                }
            }
            'recent' {
                $entries=@($script:completionHistory|Where-Object {$record=$_;@($config.instances|Where-Object {$_.id -eq $record.instanceId}).Count -eq 1})
                $pages=[Math]::Max(1,[int][Math]::Ceiling($entries.Count/4.0));$script:quickRecentPage=[Math]::Max(0,[Math]::Min($script:quickRecentPage,$pages-1))
                $script:quickSubtitle.Text=if($entries.Count){'本次运行 · 共 '+$entries.Count+' 条'}else{'本次运行'}
                $y=0
                foreach($event in @($entries|Select-Object -Skip ($script:quickRecentPage*4) -First 4)){
                    $instance=@($config.instances|Where-Object {$_.id -eq $event.instanceId})[0]
                    $title=([string](Get-ObjectValue $event 'title' '任务已完成') -replace '[\p{Cc}\p{Cf}]',' ').Trim();if(-not $title){$title='任务已完成'}
                    [void](Add-QuickPopupRow $title (Get-InstanceDisplayName $instance $script:preferences) @{action='task';role=$instance.role;threadId=$event.threadId} $y $available 'clock');$y+=68
                }
                if(-not $entries.Count){[void](Add-QuickPopupRow '还没有完成记录' '本次运行的完成任务会显示在这里' @{action='none'} 0 $false 'clock')}
                else{
                    if($pages -gt 1){
                        $previous=New-UiButton $script:quickBody '上一页' 0 284 98 {Invoke-QuickPopupCommand @{action='recent-prev'}};$previous.Enabled=$script:quickRecentPage -gt 0
                        $counter=New-UiLabel $script:quickBody (($script:quickRecentPage+1).ToString()+' / '+$pages) 112 288 90 25;$counter.TextAlign='MiddleCenter';$counter.Name='Muted';$counter.ForeColor=[CodexDual.AppTheme]::Muted
                        $next=New-UiButton $script:quickBody '下一页' 218 284 98 {Invoke-QuickPopupCommand @{action='recent-next'}};$next.Enabled=$script:quickRecentPage -lt $pages-1
                    }
                    [void](Add-QuickPopupRow '清除最近记录' '' @{action='clear'} 334 $true 'close')
                }
            }
            'directories' {
                $y=0
                foreach($role in @('api','official')){$instance=@($config.instances|Where-Object {$_.role -eq $role})[0];[void](Add-QuickPopupRow (Get-InstanceDisplayName $instance $script:preferences) '项目、无项目任务与配置目录' @{action='folders';role=$role} $y $true 'folder');$y+=70}
            }
            'folders' {
                $instance=@($config.instances|Where-Object {$_.role -eq $script:quickPopupRole})[0];$script:quickSubtitle.Text=Get-InstanceDisplayName $instance $script:preferences
                $y=0;foreach($entry in @(@('projects','项目目录'),@('projectless','无项目任务目录'),@('home','配置目录'))){[void](Add-QuickPopupRow $entry[1] '' @{action='directory';role=$instance.role;kind=$entry[0]} $y $available 'folder');$y+=48}
            }
            'more' {
                [void](Add-QuickPopupRow '同时打开两边' '' @{action='both'} 0 $available 'window')
                [void](Add-QuickPopupRow '渠道与配置' '' @{action='configure'} 46 $available 'settings')
                [void](Add-QuickPopupRow '外观' '' @{action='page';page='appearance'} 92 $true 'settings')
                [void](Add-QuickPopupRow '偏好设置' '' @{action='settings'} 138 $true 'settings')
                [void](Add-QuickPopupRow '检查环境' '' @{action='diagnostics'} 184 $available 'panel')
                [void](Add-QuickPopupRow '退出官方环境…' '' @{action='close';role='official'} 238 $available 'close')
                [void](Add-QuickPopupRow '退出 API 环境…' '' @{action='close';role='api'} 284 $available 'close')
                [void](Add-QuickPopupRow '退出控制器' '' @{action='quit'} 336 $available 'close')
            }
        }
    }finally{$script:quickBody.ResumeLayout($true)}
    Set-UiTheme $script:quickPopup
    # Keep keyboard focus inside the new page after disposing the previously focused row.
    $first=@($script:quickBody.Controls|Where-Object {$_.Enabled -and $_ -is [Windows.Forms.Button]})|Select-Object -First 1
    if($script:quickPopup.Visible -and $first){[void]$first.Focus()}
}
function Refresh-QuickPopupState {
    if(-not $script:quickPopup -or -not $script:quickPopup.Visible){return}
    $available=-not ($script:uiBusy -or $script:openBusy)
    if($script:quickPopupPage -eq 'notifications'){$stamp=$(if($script:completionReady){Get-CompletionStatusText}else{'通知暂不可用'})+'|'+($script:completionReady -and $script:completionSettings.enabled);if($stamp -ne $script:quickNotificationStamp){Set-QuickPopupPage 'notifications' -Refresh}}
    foreach($row in $script:quickBody.Controls){
        if($row.Tag -is [System.Collections.IDictionary] -and $row.Tag.action -in @('open','both','configure','diagnostics','directory','task','close','quit')){$row.Enabled=$available}
    }
    foreach($role in @('api','official')){if($script:quickPopupRows.ContainsKey($role)){$script:quickPopupRows[$role].Detail=Get-QuickPopupStatus $role;$script:quickPopupRows[$role].Invalidate()}}
}
function Show-QuickPopup([Drawing.Point]$Anchor=[Windows.Forms.Cursor]::Position,[string]$Page='home') {
    if(-not $script:quickPopup -or $script:quickPopup.IsDisposed){return}
    $script:quickNavigation.Clear();$script:quickPopupPage='home';Set-QuickPopupPage $Page
    $script:quickPopup.ShowAt($Anchor,[Windows.Forms.Screen]::FromPoint($Anchor).WorkingArea)
    $first=@($script:quickBody.Controls|Where-Object {$_.Enabled -and $_ -is [Windows.Forms.Button]})|Select-Object -First 1;if($first){[void]$first.Focus()}
}
function Go-QuickPopupBack {
    $page='home'
    if($script:quickNavigation.Count){$index=$script:quickNavigation.Count-1;$page=$script:quickNavigation[$index];$script:quickNavigation.RemoveAt($index)}
    Set-QuickPopupPage $page -Refresh
}
function Invoke-QuickPopupCommand($Command) {
    if($Command.action -in @('notification-toggle','notification-preview','snooze','dismiss','clear')){
        $request=@{action=$Command.action}
        if($Command.action -eq 'notification-toggle'){$request=@{action='toggle';enabled=(-not $script:completionSettings.enabled)}}
        elseif($Command.action -eq 'notification-preview'){$request=@{action='preview'}}
        elseif($Command.action -eq 'snooze'){$request=@{action='snooze';minutes=$Command.minutes}}
        Invoke-NotificationUiAction $request;return
    }
    if($Command.action -in @('appearance-mode','appearance-accent')){
        try{if($Command.action -eq 'appearance-mode'){Set-ControllerAppearance -Mode $Command.value}else{Set-ControllerAppearance -Accent $Command.value};Set-QuickPopupPage 'appearance' -Refresh}catch{Show-Error $_};return
    }
    if($Command.action -eq 'page'){if($Command.page -eq 'recent'){$script:quickRecentPage=0};Set-QuickPopupPage $Command.page;return}
    if($Command.action -eq 'recent-next'){$script:quickRecentPage++;Set-QuickPopupPage 'recent';return}
    if($Command.action -eq 'recent-prev'){$script:quickRecentPage--;Set-QuickPopupPage 'recent';return}
    if($Command.action -eq 'folders'){$script:quickPopupRole=$Command.role;Set-QuickPopupPage 'folders';return}
    if($Command.action -eq 'none'){return}
    if($Command.action -in @('open','both','configure','diagnostics','directory','task','close','quit') -and ($script:uiBusy -or $script:openBusy)){return}
    $script:quickPopup.Hide()
    # End the menu interaction before dispatching any command, including modal confirmations.
    try{
        $instance=if(Get-ObjectValue $Command 'role' ''){@($config.instances|Where-Object {$_.role -eq $Command.role})[0]}else{$null}
        switch($Command.action){
            'open' {Invoke-PanelAction {Open-PanelInstance $instance}}
            'panel' {Show-ControlPanel}
            'both' {Invoke-PanelAction {Open-BothPanelInstances}}
            'configure' {Show-ControlPanel;Show-ApiManager}
            'settings' {Show-ControlPanel;Show-WorkspacePage 'settings'}
            'diagnostics' {Show-ControlPanel;Show-ControllerDiagnostics}
            'directory' {Invoke-PanelAction {Open-InstanceDirectory $instance $Command.kind}}
            'task' {Invoke-PanelAction {Open-CompletionTarget $instance $Command.threadId}}
            'snooze' {Set-CompletionSnooze ([int]$Command.minutes)}
            'dismiss' {Close-CompletionCards}
            'clear' {$script:completionHistory=@()}
            'close' {Show-ControlPanel;Invoke-PanelAction {Close-Instance $instance}}
            'quit' {$script:quittingController=$true;$context.ExitThread()}
        }
    }catch{Set-UiMessage $_.Exception.Message;if($Command.action -eq 'task'){Show-TaskNavigationFeedback $_.Exception.Message}else{Show-ControlPanel;Show-Error $_}}
}
