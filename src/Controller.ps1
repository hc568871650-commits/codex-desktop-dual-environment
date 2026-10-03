param(
    [string]$ConfigPath = '',
    [ValidateSet('tray','panel','configure','official','api','status')][string]$Action = 'panel',
    [switch]$SmokeTest,
    [ValidateSet('main','api','diagnostics','settings','notifications')][string]$Preview='main',
    [string]$ScreenshotPath,
    [Action[string]]$LifecycleObserver
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\Instances.ps1"
. "$PSScriptRoot\DailyActions.ps1"
. "$PSScriptRoot\Diagnostics.ps1"
. "$PSScriptRoot\Panel.ps1"
. "$PSScriptRoot\CompletionNotifications.ps1"
. "$PSScriptRoot\PendingQuestions.ps1"
. "$PSScriptRoot\TrayMenu.ps1"
. "$PSScriptRoot\QuickPopup.ps1"
. "$PSScriptRoot\WorkspacePages.ps1"
[Windows.Forms.Application]::EnableVisualStyles()
function Show-Error($ErrorRecord) {if($SmokeTest){throw $ErrorRecord};[void][Windows.Forms.MessageBox]::Show($ErrorRecord.Exception.Message,'Codex 双环境','OK','Warning')}
try {
    if(-not $ConfigPath){$ConfigPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'instances.local.json';if(-not (Test-Path -LiteralPath $ConfigPath)){$ConfigPath=Join-Path $env:LOCALAPPDATA 'CodexDualController\instances.local.json'}}
    $config=Read-ControllerConfig $ConfigPath
    $script:preferences=Read-ControllerPreferences $config
    [void][CodexDual.AppTheme]::SetAppearance($script:preferences.appearance.mode,$script:preferences.appearance.accent)
    if($Action -eq 'status') {
        $statuses=foreach($instance in $config.instances) {
            try{$s=Get-InstanceStatus $config $instance;[pscustomobject]@{Role=$instance.role;State=$s.State;ProcessId=if($s.Process){$s.Process.Id}else{$null}}}
            catch{[pscustomobject]@{Role=$instance.role;State='Unknown';Reason=$_.Exception.Message}}
        }
        $statuses | ConvertTo-Json -Depth 4
        return
    }
    function Open-Instance($instance) {
        $process=Start-OrFindInstance $config $instance
        [void](Request-NativeInstanceActivation $instance $process)
        $windows=@(Get-InstanceWindows $instance $process | Where-Object {$_.Visible})
        for($retry=0;$windows.Count -eq 0 -and $retry -lt 10;$retry++){Start-Sleep -Milliseconds 300;$windows=@(Get-InstanceWindows $instance $process | Where-Object {$_.Visible})}
        if($windows.Count -eq 0){throw '已确认实例运行，但应用尚未原生显示主窗口。不会强行显示隐藏窗口；请从原生托盘恢复。'}
        Complete-InstanceOpen $instance $process $windows
    }
    function Complete-InstanceOpen($instance,$process,$windows) {
        $selected=$windows[0]
        if($windows.Count -gt 1) {
            $dialog=New-Object Windows.Forms.Form;$dialog.Text='选择要显示的窗口';$dialog.Size=New-Object Drawing.Size(650,300);$dialog.StartPosition='CenterScreen'
            $list=New-Object Windows.Forms.ListBox;$list.Dock='Fill'
            foreach($w in $windows){[void]$list.Items.Add($w.Title+'  [窗口 '+$w.Handle+']')};$list.SelectedIndex=0
            $button=New-Object Windows.Forms.Button;$button.Text='显示选中窗口';$button.Dock='Bottom';$button.DialogResult='OK'
            $dialog.Controls.Add($list);$dialog.Controls.Add($button);$dialog.AcceptButton=$button
            try{if($dialog.ShowDialog() -ne 'OK'){return 'Cancelled'};$selected=$windows[$list.SelectedIndex]}finally{$dialog.Dispose()}
        }
        if(-not (Show-InstanceWindow $instance $process $selected.Handle)){
            return 'Running'
        }
        return 'Shown'
    }
    function Close-Instance($instance) {
        Invoke-InstanceLocked $instance {
            $status=Get-InstanceStatus $config $instance;if($status.State -eq 'Stopped'){return}
            $process=$status.Process;Assert-NotCurrentHost $process
            $label=Get-InstanceDisplayName $instance (Read-ControllerPreferences $config)
            $answer=[Windows.Forms.MessageBox]::Show("退出$label？无法可靠查询任务状态。请先在该实例中确认没有正在执行的任务；关闭窗口也可能仅隐藏到原生托盘。",'确认退出','YesNo','Warning','Button2')
            if($answer -ne 'Yes'){return}
            $before=Get-ProcessSnapshot;$owned=@(Get-OwnedDesktopChildren $process $before)
            Request-InstanceClose $instance $process
            $alive=-not (Wait-ExpectedProcessExitUi -Expected $process -Message ('正在退出 '+$label+'…') -TimeoutMilliseconds 3000)
            if($alive) {
                $answer=[Windows.Forms.MessageBox]::Show("$label 仍在后台运行。是否强制结束已核验的桌面进程？可能中断任务和丢失未保存内容。不会结束任务启动的服务器、编辑器或无法确认归属的进程。",'正常退出未完成','YesNo','Warning','Button2')
                if($answer -eq 'Yes'){$owned=@(Stop-InstanceForced $instance $process -UserConfirmed);[void](Wait-ExpectedProcessExitUi -Expected $process -Message ('正在强制结束 '+$label+'…') -TimeoutMilliseconds 2000)}
            }
            $residual=@(Get-ExitResiduals $before $owned)
            if($residual.Count){$text=($residual | ForEach-Object {"PID $($_.Id) / $($_.Name) / "+$(if($_.VerifiedDesktop){'桌面进程仍驻留'}else{'归属/用途未充分确认，保留'})}) -join "`r`n"}
            else{$text='已核验的进程已退出。未观察到原进程树残留；这不代表所有外部应用都已关闭。'}
            [void][Windows.Forms.MessageBox]::Show($text,'退出结果')
        }
    }
    if($Action -in @('official','api')) {$outcome=Open-Instance @($config.instances | Where-Object {$_.role -eq $Action})[0];if($outcome -eq 'Running'){[void][Windows.Forms.MessageBox]::Show('目标窗口已恢复，但 Windows 拒绝抢占前台。请点击其任务栏窗口。','Codex 双环境')};return}
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $hashAlgorithm=[Security.Cryptography.SHA256]::Create()
    try{$configHash=[BitConverter]::ToString($hashAlgorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($ConfigPath).ToLowerInvariant()))).Replace('-','')}finally{$hashAlgorithm.Dispose()}
    $eventName='Local\CodexDual.Panel.'+$sid+'.'+$configHash
    $tray=$null;$menu=$null;$trayClick=$null;$script:quickPopup=$null
    $script:statusWork=$null;$script:openWork=$null
    $panel=$null;$panelEvent=$null;$configureEvent=$null;$panelTimer=$null;$script:quittingController=$false;$script:completionReady=$false
    $mutexName='Local\CodexDual.Controller.'+$sid
    if($SmokeTest){$mutexName+='.Smoke.'+$configHash}
    $mutex=New-Object Threading.Mutex($false,$mutexName);$held=$false
    try{try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){if($SmokeTest){throw 'Controller already running'}
            try{$requestedEvent=if($Action -eq 'configure'){$eventName+'.Configure'}else{$eventName};$otherEvent=[Threading.EventWaitHandle]::OpenExisting($requestedEvent);try{[void]$otherEvent.Set()}finally{$otherEvent.Dispose()};return}catch{}
            [void][Windows.Forms.MessageBox]::Show('其他配置的控制器已经运行，请先从其托盘退出控制器再打开此入口。Codex 不需要退出。','Codex 双环境');return
        }
        $context=New-Object Windows.Forms.ApplicationContext
        $tray=New-Object Windows.Forms.NotifyIcon
        $iconPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\controller.ico'
        if(Test-Path -LiteralPath $iconPath){$tray.Icon=New-Object Drawing.Icon($iconPath)}else{$tray.Icon=[Drawing.SystemIcons]::Application}
        $controllerLabel=[string](Get-ObjectValue $config 'displayName' 'Codex 双环境')
        if($controllerLabel.Length -gt 63){$controllerLabel=$controllerLabel.Substring(0,63)}
        $tray.Text=$controllerLabel;$menu=New-Object CodexDual.QuietMenu
        $script:uiBusy=$false;$script:openBusy=$false;$script:positionInitialized=$false;$script:apiDialog=$null
        $script:statusWork=New-Object CodexDual.BackgroundWork
        $script:openWork=New-Object CodexDual.BackgroundWork
        $script:workCode=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ControllerWork.ps1'))
        $script:statusCache=@{};$script:statusRequested=[DateTime]::MinValue
        $script:apiInstance=@($config.instances|Where-Object {$_.role -eq 'api'})[0]
        $script:openMenus=@{};$script:closeMenus=@{};$script:instanceNames=@{}
        [void]$menu.Items.Add($controllerLabel);$menu.Items[0].Enabled=$false
        $labels=@{}
        foreach($role in @('official','api')){$item=$menu.Items.Add('状态读取中');$item.Enabled=$false;$labels[$role]=$item}
        [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        foreach($role in @('official','api')){
            $entry=$menu.Items.Add($(if($role -eq 'official'){'启动或显示官方版'}else{'启动或显示 API 版'}));$entry.Tag=$role
            $script:openMenus[$role]=$entry
            $entry.Add_Click({param($sender,$eventArgs) $sender.Owner.Close();[Windows.Forms.Application]::DoEvents();$target=$sender.Tag;Invoke-PanelAction {Open-PanelInstance @($config.instances | Where-Object {$_.role -eq $target})[0]}})
        }
        $bothEntry=$menu.Items.Add('同时打开两边');$bothEntry.Add_Click({$menu.Close();Show-ControlPanel;Invoke-PanelAction {Open-BothPanelInstances}})
        [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        foreach($role in @('official','api')){
            $entry=$menu.Items.Add($(if($role -eq 'official'){'退出官方版…'}else{'退出 API 版…'}));$entry.Tag=$role
            $script:closeMenus[$role]=$entry
            $entry.Add_Click({param($sender,$eventArgs) $sender.Owner.Close();$target=$sender.Tag;Invoke-PanelAction {Close-Instance @($config.instances | Where-Object {$_.role -eq $target})[0]}})
        }
        [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        $exitItem=$menu.Items.Add('退出控制器');$exitItem.Add_Click({if($script:openBusy){Show-ControlPanel;return};$script:quittingController=$true;$context.ExitThread()})
        $menu.Add_Opening({param($sender,$e)
            Update-PanelStatus
        })
        $tray.Visible=$true
        if(-not ('CodexDual.TrayClick' -as [type])){Add-Type -Path "$PSScriptRoot\TrayClick.cs" -ReferencedAssemblies System.Windows.Forms}
        $trayClick=New-Object CodexDual.TrayClick
        $tray.Add_MouseDown({param($sender,$eventArgs) $trayClick.HandleMouseDown($eventArgs.Button)})
        $trayClick.add_SingleClick({if($script:quickPopup){$script:quickPopup.Hide()};Invoke-PanelAction {Open-PanelInstance $script:apiInstance}})
        $trayClick.add_DoubleClick({if($script:quickPopup){$script:quickPopup.Hide()};Show-ControlPanel})
        $tray.Add_MouseUp({param($sender,$eventArgs) if($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Right){Show-QuickPopup}})
        $panel=New-Object CodexDual.ShellForm;$panel.AppWindow=$true
        $version=(Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'version.json') -Raw -Encoding UTF8|ConvertFrom-Json).version
        $panel.Text=$controllerLabel+' · '+$version;$panel.ClientSize=New-Object Drawing.Size(840,548)
        $panel.FormBorderStyle='FixedSingle';$panel.MaximizeBox=$false;$panel.StartPosition='Manual'
        $panel.Icon=$tray.Icon;$panel.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5)
        $panel.BackColor=[CodexDual.AppTheme]::Background;$panel.ForeColor=[CodexDual.AppTheme]::Text
        $sidebar=New-Object Windows.Forms.Panel;$sidebar.Name='Sidebar';$sidebar.SetBounds(1,0,183,548);$sidebar.BackColor=[CodexDual.AppTheme]::Sidebar;$panel.Controls.Add($sidebar)
        $brand=New-UiLabel $sidebar 'Codex' 20 14 150 48;$brand.Font=New-Object Drawing.Font('Segoe UI',20,[Drawing.FontStyle]::Bold)
        $brandNote=New-UiLabel $sidebar '双环境工作台' 22 67 145 27;$brandNote.ForeColor=[CodexDual.AppTheme]::Muted
        $overviewNav=New-UiButton $sidebar '概览' 12 112 158 {Show-WorkspacePage 'overview'};$overviewNav.Height=40;$overviewNav.Quiet=$true;$overviewNav.Selected=$true;$overviewNav.TextAlign='MiddleLeft'
        $channelNav=New-UiButton $sidebar '渠道与配置' 12 160 158 {if(-not $script:openBusy){Show-ApiManager}};$channelNav.Height=40;$channelNav.Quiet=$true;$channelNav.TextAlign='MiddleLeft'
        $notificationNav=New-UiButton $sidebar '通知' 12 208 158 {Show-WorkspacePage 'notifications'};$notificationNav.Height=40;$notificationNav.Quiet=$true;$notificationNav.TextAlign='MiddleLeft'
        $settingsNav=New-UiButton $sidebar '偏好设置' 12 256 158 {Show-WorkspacePage 'settings'};$settingsNav.Height=40;$settingsNav.Quiet=$true;$settingsNav.TextAlign='MiddleLeft'
        $diagnosticNav=New-UiButton $sidebar '检查环境' 12 418 158 {Show-ControllerDiagnostics};$diagnosticNav.Height=36;$diagnosticNav.Quiet=$true;$diagnosticNav.TextAlign='MiddleLeft'
        $exitNav=New-UiButton $sidebar '退出工具' 12 458 158 {if($script:openBusy){Set-UiMessage '请等待窗口打开操作结束，再退出工具。';return};Save-PanelPosition;$script:quittingController=$true;$context.ExitThread()};$exitNav.Height=36;$exitNav.Quiet=$true;$exitNav.TextAlign='MiddleLeft'
        $versionLabel=New-UiLabel $sidebar ('版本 '+$version) 24 513 145 23;$versionLabel.ForeColor=[CodexDual.AppTheme]::Muted;$versionLabel.Font=New-Object Drawing.Font($panel.Font.FontFamily,8)
        $overviewPage=New-Object Windows.Forms.Panel;$overviewPage.SetBounds(208,18,608,462);$panel.Controls.Add($overviewPage)
        $heading=New-UiLabel $overviewPage '你的工作环境' 0 0 420 52;$heading.Font=New-Object Drawing.Font($panel.Font.FontFamily,20,[Drawing.FontStyle]::Bold)
        $subtitle=New-UiLabel $overviewPage '两个独立窗口，按你的分工协作。' 1 59 420 28;$subtitle.ForeColor=[CodexDual.AppTheme]::Muted
        $bothButton=New-UiButton $overviewPage '同时打开两边' 456 18 152 {Invoke-PanelAction {Open-BothPanelInstances}};$bothButton.Height=40
        $panelLabels=@{};$script:instanceOpenButtons=@{}
        foreach($role in @('official','api')){
            $x=if($role -eq 'official'){0}else{314}
            $card=New-Object CodexDual.Surface;$card.SetBounds($x,105,294,222);$overviewPage.Controls.Add($card)
            $eyebrow=New-UiLabel $card $(if($role -eq 'official'){'OFFICIAL'}else{'API'}) 20 17 254 20;$eyebrow.ForeColor=[CodexDual.AppTheme]::Muted;$eyebrow.Font=New-Object Drawing.Font('Segoe UI',8,[Drawing.FontStyle]::Bold)
            $name=New-UiLabel $card '' 20 42 254 40;$name.AutoEllipsis=$true;$name.Font=New-Object Drawing.Font($panel.Font.FontFamily,15,[Drawing.FontStyle]::Bold);$script:instanceNames[$role]=$name
            $label=New-UiLabel $card '正在检查状态…' 20 84 254 25;$label.AutoEllipsis=$true;$label.ForeColor=[CodexDual.AppTheme]::Muted;$panelLabels[$role]=$label
            $button=New-UiButton $card '打开' 18 126 160 {param($sender,$e) $target=$sender.Tag;Invoke-PanelAction {Open-PanelInstance @($config.instances|Where-Object {$_.role -eq $target})[0]}};$button.Tag=$role;$button.Primary=$true;$button.Height=38;$script:instanceOpenButtons[$role]=$button
            $closeButton=New-UiButton $card '退出…' 188 126 88 {param($sender,$e) $target=$sender.Tag;Invoke-PanelAction {Close-Instance @($config.instances|Where-Object {$_.role -eq $target})[0]}};$closeButton.Tag=$role;$closeButton.Quiet=$true;$closeButton.Height=38
            $folders=New-UiButton $card '常用目录…' 14 178 166 {param($sender,$e) $target=$sender.Tag;Show-InstanceDirectoryMenu @($config.instances|Where-Object {$_.role -eq $target})[0] $sender};$folders.Tag=$role;$folders.Quiet=$true;$folders.TextAlign='MiddleLeft'
            $rename=New-UiButton $card '改名' 198 178 78 {param($sender,$e) $target=$sender.Tag;Show-NameDialog @($config.instances|Where-Object {$_.role -eq $target})[0]};$rename.Tag=$role;$rename.Quiet=$true
        }
        $channelSurface=New-Object CodexDual.Surface;$channelSurface.SetBounds(0,347,608,110);$overviewPage.Controls.Add($channelSurface)
        $script:apiSummary=New-UiLabel $channelSurface 'API 渠道' 18 14 570 25;$script:apiSummary.AutoEllipsis=$true;$script:apiSummary.ForeColor=[CodexDual.AppTheme]::Muted
        $script:profilePicker=New-Object CodexDual.QuietComboBox;$script:profilePicker.DropDownStyle='DropDownList';$script:profilePicker.SetBounds(20,55,318,32);$channelSurface.Controls.Add($script:profilePicker)
        $script:applyButton=New-UiButton $channelSurface '应用渠道' 350 53 110 {Invoke-PanelAction {Apply-SelectedProfile $script:profilePicker.SelectedItem $false}};$script:applyButton.Height=36
        $manage=New-UiButton $channelSurface '管理 API' 470 53 118 {if(-not $script:openBusy){Show-ApiManager}};$manage.Height=36;$manage.Quiet=$true
        Initialize-PreferencesPage $panel;Initialize-NotificationsPage $panel
        $settingsPage=$script:settingsPage;$settingsHeading=$script:settingsHeading
        $script:feedback=New-UiLabel $panel '托盘：单击打开 API 版，双击打开工作台。' 210 501 600 38;$script:feedback.ForeColor=[CodexDual.AppTheme]::Muted;$script:feedback.Font=New-Object Drawing.Font($panel.Font.FontFamily,8.5)
        function Show-WorkspacePage([ValidateSet('overview','notifications','settings')][string]$Name){
            $settingsPage.Visible=$Name -eq 'settings';$overviewPage.Visible=$Name -eq 'overview';$script:notificationsPage.Visible=$Name -eq 'notifications'
            $overviewNav.Selected=$overviewPage.Visible;$settingsNav.Selected=$settingsPage.Visible;$notificationNav.Selected=$script:notificationsPage.Visible
            $overviewNav.Invalidate();$settingsNav.Invalidate();$notificationNav.Invalidate()
            if($Name -eq 'notifications'){Update-NotificationView -Force}
        }
        $panel.AddTitleBar()
        function Update-PanelStatus {
            if($script:statusWork.Completed){
                try{foreach($result in $script:statusWork.Take()){$script:statusCache[$result.Role]=$result}}
                catch{$script:statusCache.Clear()}
            }
            foreach($instance in $config.instances){
                $kind=if($instance.role -eq 'official'){'官方订阅'}else{'API'}
                $s=$script:statusCache[$instance.role]
                if($s){
                    $script:instanceOpenButtons[$instance.role].Text=if($s.State -eq 'Running'){'显示窗口'}elseif($s.State -eq 'Stopped'){'启动'}else{'打开'}
                    $panelLabels[$instance.role].Text=$kind+' · '+$(switch($s.State){'Running'{'已运行'};'Stopped'{'未启动'};default{'状态未知'}})
                    $pending=Get-ObjectValue $script:preferences 'pendingApi' $null
                    if($instance.role -eq 'api' -and $pending -and $s.State -eq 'Running' -and $s.Process.Id -eq $pending.pid -and $s.Process.Started -eq $pending.started){$panelLabels[$instance.role].Text='API · 已运行，配置待重启'}
                    $labels[$instance.role].Text=(Get-InstanceDisplayName $instance $script:preferences).Replace('&','&&')+'：'+$s.Reason
                }else{$panelLabels[$instance.role].Text=$kind+' · 正在检查';$labels[$instance.role].Text=$panelLabels[$instance.role].Text}
            }
            Refresh-QuickPopupState
            if(-not $script:statusWork.Busy -and ([DateTime]::UtcNow-$script:statusRequested).TotalSeconds -ge 2){
                $script:statusRequested=[DateTime]::UtcNow
                $script:statusWork.Start($script:workCode,[object[]]@($PSScriptRoot,$ConfigPath,'status',[string[]]@()))
            }
        }
        Update-PanelNames;Update-ApiSummary
        $panel.Add_ResizeEnd({Save-PanelPosition})
        $panel.Add_FormClosing({param($sender,$e)Save-PanelPosition;if(-not $script:quittingController -and $e.CloseReason -eq 'UserClosing'){$e.Cancel=$true;$panel.Hide()}})
        $openPanelItem=New-Object Windows.Forms.ToolStripMenuItem('打开控制面板');$openPanelItem.Add_Click({$menu.Close();Show-ControlPanel});$menu.Items.Insert(1,$openPanelItem)
        $apiMenu=New-Object Windows.Forms.ToolStripMenuItem('管理 API');$apiMenu.Add_Click({$menu.Close();Show-ControlPanel;if(-not $script:openBusy){Show-ApiManager}});$menu.Items.Insert(2,$apiMenu)
        try{Initialize-CompletionNotifications;$script:completionReady=$true}
        catch{Set-UiMessage '通知未能启动，请在控制台检查设置。'}
        $notificationEnabled.Enabled=$script:completionReady;if($script:completionReady){$notificationEnabled.Checked=$script:completionSettings.enabled}
        Initialize-PendingQuestions
        $pendingMenu=New-Object Windows.Forms.ToolStripMenuItem('待处理问题');$pendingMenu.Add_Click({$menu.Close();$script:notificationListMode='pending';Show-ControlPanel;Show-WorkspacePage 'notifications'});$menu.Items.Insert(4,$pendingMenu)
        Initialize-QuickMenu;Initialize-QuickPopup;Update-ControllerAppearance -Force;Update-NotificationView -Force
        $panelEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,$eventName)
        $configureEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,($eventName+'.Configure'))
        $panelTimer=New-Object Windows.Forms.Timer;$panelTimer.Interval=50;$script:refreshTicks=0;$script:completionTicks=0;$panelTimer.Add_Tick({
            if($script:uiBusy){return};if($panelEvent.WaitOne(0)){Show-ControlPanel}
            if(-not $script:openBusy -and $configureEvent.WaitOne(0)){Show-ControlPanel;Show-ApiManager}
            if($script:openWork.Completed){Receive-PanelOpen}
            Update-PendingQuestions
            $script:completionTicks++;if($script:completionReady -and $script:completionTicks -ge 20){$script:completionTicks=0;Update-CompletionNotifications;Update-NotificationView;if($script:preferences.appearance.mode -eq 'system'){Update-ControllerAppearance};Refresh-QuickPopupState}
            $script:refreshTicks++;if($script:statusWork.Completed -or (($panel.Visible -or $menu.Visible -or $script:quickPopup.Visible) -and $script:refreshTicks -ge 40)){$script:refreshTicks=0;Update-PanelStatus}
        });$panelTimer.Start()
        if($SmokeTest){
            if($Action -in @('panel','configure')){
                Show-ControlPanel;[Windows.Forms.Application]::DoEvents()
                $originalPoint=$panel.Location
                $panel.Hide();Show-ControlPanel
                if($panel.Location -ne $originalPoint -or -not $panel.Visible){throw 'Panel position retention failed'}
                $panel.Hide()
                # Replace the launch boundary only in this disposable smoke process.
                $script:smokeTrayRole=''
                function Open-PanelInstance($Instance){$script:smokeTrayRole=$Instance.role}
                function Wait-SmokeUi([int]$Milliseconds){$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.ElapsedMilliseconds -lt $Milliseconds){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 5}}
                $mouse=New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left,1,0,0,0)
                $method=$tray.GetType().GetMethod('OnMouseDown',[Reflection.BindingFlags]'Instance,NonPublic')
                [void]$method.Invoke($tray.PSObject.BaseObject,[object[]]@($mouse.PSObject.BaseObject))
                if($panel.Visible -or $script:smokeTrayRole){throw 'First tray press must wait for double-click arbitration'}
                Wait-SmokeUi ($trayClick.Interval+100)
                if($script:smokeTrayRole -ne 'api' -or $panel.Visible){throw 'Tray single click must route only to API without showing the panel'}
                $script:smokeTrayRole=''
                [void]$method.Invoke($tray.PSObject.BaseObject,[object[]]@($mouse.PSObject.BaseObject))
                Wait-SmokeUi ($trayClick.Interval-100)
                [void]$method.Invoke($tray.PSObject.BaseObject,[object[]]@($mouse.PSObject.BaseObject))
                Wait-SmokeUi ($trayClick.Interval+100)
                if(-not $panel.Visible -or $menu.Visible -or $panel.Location -ne $originalPoint -or $script:smokeTrayRole){throw 'Double click must reveal the stationary panel without opening an instance'}
                $settingsNav.PerformClick()
                if(-not $settingsPage.Visible -or $overviewPage.Visible){throw 'Settings navigation failed'}
                $overviewNav.PerformClick()
                if(-not $overviewPage.Visible -or $settingsPage.Visible){throw 'Overview navigation failed'}
                $notificationNav.PerformClick();[Windows.Forms.Application]::DoEvents()
                if(-not $script:notificationsPage.Visible -or $settingsPage.Visible){throw 'Notification must open its own page'}
                Show-WorkspacePage 'overview'
                foreach($largeLabel in @($brand,$heading,$settingsHeading)){
                    $required=[Windows.Forms.TextRenderer]::MeasureText($largeLabel.Text,$largeLabel.Font)
                    if($largeLabel.Height -lt $required.Height){throw ('Heading is clipped: '+$largeLabel.Text)}
                }
                Write-Output ('PASS: tray single API / near-deadline double panel / page navigation / title fit ('+$trayClick.Interval+'ms)')
                if($Preview -eq 'notifications'){Show-WorkspacePage 'notifications';[Windows.Forms.Application]::DoEvents();if($ScreenshotPath){Save-UiScreenshot $panel $ScreenshotPath}}elseif($Preview -eq 'settings'){Show-WorkspacePage 'settings';[Windows.Forms.Application]::DoEvents();if($ScreenshotPath){Save-UiScreenshot $panel $ScreenshotPath}}elseif($Preview -eq 'api'){Show-ApiManager}elseif($Preview -eq 'diagnostics'){Show-ControllerDiagnostics}elseif($ScreenshotPath){Save-UiScreenshot $panel $ScreenshotPath}
            }else{
            $mouse=New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Right,1,0,0,0)
            $method=$tray.GetType().GetMethod('OnMouseUp',[Reflection.BindingFlags]'Instance,NonPublic')
            [void]$method.Invoke($tray.PSObject.BaseObject,[object[]]@($mouse.PSObject.BaseObject));[Windows.Forms.Application]::DoEvents()
            if(-not $script:quickPopup.Visible -or $tray.ContextMenuStrip){throw 'Right click must show the custom popup only'}
            if($ScreenshotPath){Save-UiScreenshot $script:quickPopup $ScreenshotPath}
            $script:quickPopup.Hide()
            }
        }else{if($Action -in @('panel','configure')){Show-ControlPanel};if($LifecycleObserver){$LifecycleObserver.Invoke('ready-'+$Action)};if($Action -eq 'configure'){Show-ApiManager};[Windows.Forms.Application]::Run($context)}
    }finally{Dispose-PendingQuestions;if($script:quickPopup){$script:quickPopup.Dispose()};if($menu){$menu.Dispose()};if($trayClick){$trayClick.Dispose()};if($panelTimer){$panelTimer.Stop();$panelTimer.Dispose()};if($script:statusWork){$script:statusWork.Dispose()};if($script:openWork){$script:openWork.Dispose()};if($script:completionReady){Dispose-CompletionNotifications};if($panelEvent){$panelEvent.Dispose()};if($configureEvent){$configureEvent.Dispose()};if($panel){$panel.Dispose()};if($tray){$tray.Visible=$false;$tray.Dispose()};if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}catch{if($LifecycleObserver){$LifecycleObserver.Invoke('failed-'+$_.Exception.GetType().FullName)};if($Action -eq 'status' -or $SmokeTest){throw};Show-Error $_;exit 1}
