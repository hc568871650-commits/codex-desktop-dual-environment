param(
    [string]$ConfigPath = '',
    [ValidateSet('tray','panel','configure','official','api','status')][string]$Action = 'panel',
    [switch]$SmokeTest,
    [ValidateSet('main','api')][string]$Preview='main',
    [string]$ScreenshotPath,
    [Action[string]]$LifecycleObserver
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\Instances.ps1"
. "$PSScriptRoot\Panel.ps1"
[Windows.Forms.Application]::EnableVisualStyles()
function Show-Error($ErrorRecord) {if($SmokeTest){throw $ErrorRecord};[void][Windows.Forms.MessageBox]::Show($ErrorRecord.Exception.Message,'Codex 双环境','OK','Warning')}
try {
    if(-not $ConfigPath){$ConfigPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'instances.local.json';if(-not (Test-Path -LiteralPath $ConfigPath)){$ConfigPath=Join-Path $env:LOCALAPPDATA 'CodexDualController\instances.local.json'}}
    $config=Read-ControllerConfig $ConfigPath
    $script:preferences=Read-ControllerPreferences $config
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
        $selected=$windows[0]
        if($windows.Count -gt 1) {
            $dialog=New-Object Windows.Forms.Form;$dialog.Text='选择要显示的窗口';$dialog.Size=New-Object Drawing.Size(650,300);$dialog.StartPosition='CenterScreen'
            $list=New-Object Windows.Forms.ListBox;$list.Dock='Fill'
            foreach($w in $windows){[void]$list.Items.Add($w.Title+'  [窗口 '+$w.Handle+']')};$list.SelectedIndex=0
            $button=New-Object Windows.Forms.Button;$button.Text='显示选中窗口';$button.Dock='Bottom';$button.DialogResult='OK'
            $dialog.Controls.Add($list);$dialog.Controls.Add($button);$dialog.AcceptButton=$button
            try{if($dialog.ShowDialog() -ne 'OK'){return};$selected=$windows[$list.SelectedIndex]}finally{$dialog.Dispose()}
        }
        if(-not (Show-InstanceWindow $instance $process $selected.Handle)){
            [void][Windows.Forms.MessageBox]::Show('目标窗口已恢复，但 Windows 拒绝抢占前台。请点击其任务栏窗口。','Codex 双环境')
        }
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
    if($Action -in @('official','api')) {Open-Instance @($config.instances | Where-Object {$_.role -eq $Action})[0];return}
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $hashAlgorithm=[Security.Cryptography.SHA256]::Create()
    try{$configHash=[BitConverter]::ToString($hashAlgorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($ConfigPath).ToLowerInvariant()))).Replace('-','')}finally{$hashAlgorithm.Dispose()}
    $eventName='Local\CodexDual.Panel.'+$sid+'.'+$configHash
    $tray=$null
    $panel=$null;$panelEvent=$null;$configureEvent=$null;$panelTimer=$null;$script:quittingController=$false
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
        $tray.Text=$controllerLabel;$menu=New-Object Windows.Forms.ContextMenuStrip
        $script:uiBusy=$false;$script:positionInitialized=$false;$script:apiDialog=$null
        $script:apiInstance=@($config.instances|Where-Object {$_.role -eq 'api'})[0]
        $script:openMenus=@{};$script:closeMenus=@{};$script:instanceNames=@{}
        [void]$menu.Items.Add($controllerLabel);$menu.Items[0].Enabled=$false
        $labels=@{}
        foreach($role in @('official','api')){$item=$menu.Items.Add('状态读取中');$item.Enabled=$false;$labels[$role]=$item}
        [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        foreach($role in @('official','api')){
            $entry=$menu.Items.Add($(if($role -eq 'official'){'启动或显示官方版'}else{'启动或显示 API 版'}));$entry.Tag=$role
            $script:openMenus[$role]=$entry
            $entry.Add_Click({param($sender,$eventArgs) $sender.Owner.Close();[Windows.Forms.Application]::DoEvents();$target=$sender.Tag;Invoke-PanelAction {Open-Instance @($config.instances | Where-Object {$_.role -eq $target})[0]}})
        }
        [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        foreach($role in @('official','api')){
            $entry=$menu.Items.Add($(if($role -eq 'official'){'退出官方版…'}else{'退出 API 版…'}));$entry.Tag=$role
            $script:closeMenus[$role]=$entry
            $entry.Add_Click({param($sender,$eventArgs) $sender.Owner.Close();$target=$sender.Tag;Invoke-PanelAction {Close-Instance @($config.instances | Where-Object {$_.role -eq $target})[0]}})
        }
        [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        $exitItem=$menu.Items.Add('退出控制器');$exitItem.Add_Click({$script:quittingController=$true;$context.ExitThread()})
        $menu.Add_Opening({param($sender,$e)
            if($script:uiBusy){$e.Cancel=$true;return}
            foreach($instance in $config.instances){$prefix=(Get-InstanceDisplayName $instance (Read-ControllerPreferences $config)).Replace('&','&&')
                try{$s=Get-InstanceStatus $config $instance;$labels[$instance.role].Text=$prefix+'：'+$s.Reason}
                catch{$labels[$instance.role].Text=$prefix+'：状态未知';$labels[$instance.role].ToolTipText=$_.Exception.Message}
            }
        })
        $tray.ContextMenuStrip=$menu;$tray.Visible=$true
        $tray.Add_MouseClick({param($sender,$eventArgs) if(-not $script:uiBusy -and $eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left){Show-ControlPanel}})
        $panel=New-Object Windows.Forms.Form
        $panel.Text=$controllerLabel+' · 0.3';$panel.ClientSize=New-Object Drawing.Size(520,366)
        $panel.FormBorderStyle='FixedSingle';$panel.MaximizeBox=$false;$panel.StartPosition='Manual'
        $panel.Icon=$tray.Icon;$panel.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
        $panel.BackColor=[Drawing.ColorTranslator]::FromHtml('#F5F7FA')
        $heading=New-UiLabel $panel '两个窗口，各自工作' 20 16 470 32;$heading.Font=New-Object Drawing.Font('Microsoft YaHei UI',14,[Drawing.FontStyle]::Bold)
        $panelLabels=@{}
        foreach($role in @('official','api')){
            $x=if($role -eq 'official'){20}else{266}
            $card=New-Object Windows.Forms.Panel;$card.SetBounds($x,58,234,122);$card.BackColor=[Drawing.Color]::White;$panel.Controls.Add($card)
            $name=New-UiLabel $card '' 12 10 210 25;$name.AutoEllipsis=$true;$name.Font=New-Object Drawing.Font('Microsoft YaHei UI',11,[Drawing.FontStyle]::Bold);$script:instanceNames[$role]=$name
            $label=New-UiLabel $card '读取状态…' 12 38 212 25;$label.AutoEllipsis=$true;$panelLabels[$role]=$label
            $button=New-UiButton $card '打开' 10 78 64 {param($sender,$e) $target=$sender.Tag;Invoke-PanelAction {Open-Instance @($config.instances|Where-Object {$_.role -eq $target})[0]}};$button.Tag=$role
            $closeButton=New-UiButton $card '退出…' 80 78 72 {param($sender,$e) $target=$sender.Tag;Invoke-PanelAction {Close-Instance @($config.instances|Where-Object {$_.role -eq $target})[0]}};$closeButton.Tag=$role
            $rename=New-UiButton $card '改名' 158 78 64 {param($sender,$e) $target=$sender.Tag;Show-NameDialog @($config.instances|Where-Object {$_.role -eq $target})[0]};$rename.Tag=$role
        }
        $script:apiSummary=New-UiLabel $panel 'API 渠道' 20 194 480 26
        $script:profilePicker=New-Object Windows.Forms.ComboBox;$script:profilePicker.DropDownStyle='DropDownList';$script:profilePicker.SetBounds(20,224,224,30);$panel.Controls.Add($script:profilePicker)
        $script:applyButton=New-UiButton $panel '应用渠道' 254 223 112 {Invoke-PanelAction {Apply-SelectedProfile $script:profilePicker.SelectedItem $false}}
        [void](New-UiButton $panel '管理 API' 376 223 124 {Show-ApiManager})
        $script:feedback=New-UiLabel $panel '关闭面板收起到托盘；窗口位置会记住。' 20 267 480 43
        $startup=New-Object Windows.Forms.CheckBox;$startup.Text='登录时自动打开控制面板';$startup.SetBounds(20,317,272,28);$panel.Controls.Add($startup)
        $toolRoot=Split-Path $PSScriptRoot -Parent
        $startup.Checked=[bool](Repair-ControllerAutoStart $toolRoot $ConfigPath)
        $startup.Add_Click({
            try{Set-ControllerAutoStart $toolRoot $ConfigPath $startup.Checked;Set-UiMessage $(if($startup.Checked){'已开启：登录后自动打开控制面板，Codex 仍由你手动打开。'}else{'已关闭控制器自启动。'})}
            catch{$startup.Checked=[bool](Test-ControllerAutoStart $toolRoot $ConfigPath);Show-Error $_}
        })
        [void](New-UiButton $panel '检查环境' 300 315 96 {Show-ControllerDiagnostics})
        [void](New-UiButton $panel '退出工具' 404 315 96 {Save-PanelPosition;$script:quittingController=$true;$context.ExitThread()})
        function Update-PanelStatus {
            foreach($instance in $config.instances){
                $kind=if($instance.role -eq 'official'){'官方订阅'}else{'API'}
                try{
                    $s=Get-InstanceStatus $config $instance
                    $panelLabels[$instance.role].Text=$kind+' · '+$(if($s.State -eq 'Running'){'已运行'}else{'未启动'})
                    $pending=Get-ObjectValue $script:preferences 'pendingApi' $null
                    if($instance.role -eq 'api' -and $pending -and $s.State -eq 'Running' -and $s.Process.Id -eq $pending.pid -and $s.Process.Started -eq $pending.started){$panelLabels[$instance.role].Text='API · 已运行，配置待重启'}
                }catch{$panelLabels[$instance.role].Text=$kind+' · 状态未知'}
            }
        }
        Update-PanelNames;Update-ApiSummary
        $panel.Add_ResizeEnd({Save-PanelPosition})
        $panel.Add_FormClosing({param($sender,$e)Save-PanelPosition;if(-not $script:quittingController -and $e.CloseReason -eq 'UserClosing'){$e.Cancel=$true;$panel.Hide()}})
        $openPanelItem=New-Object Windows.Forms.ToolStripMenuItem('打开控制面板');$openPanelItem.Add_Click({$menu.Close();Show-ControlPanel});$menu.Items.Insert(1,$openPanelItem)
        $apiMenu=New-Object Windows.Forms.ToolStripMenuItem('管理 API');$apiMenu.Add_Click({$menu.Close();Show-ControlPanel;Show-ApiManager});$menu.Items.Insert(2,$apiMenu)
        $panelEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,$eventName)
        $configureEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,($eventName+'.Configure'))
        $panelTimer=New-Object Windows.Forms.Timer;$panelTimer.Interval=250;$script:refreshTicks=0;$panelTimer.Add_Tick({
            if($script:uiBusy){return};if($panelEvent.WaitOne(0)){Show-ControlPanel}
            if($configureEvent.WaitOne(0)){Show-ControlPanel;Show-ApiManager}
            $script:refreshTicks++;if($panel.Visible -and $script:refreshTicks -ge 16){$script:refreshTicks=0;Update-PanelStatus}
        });$panelTimer.Start()
        if($SmokeTest){
            if($Action -in @('panel','configure')){
                Show-ControlPanel;[Windows.Forms.Application]::DoEvents()
                $originalPoint=$panel.Location
                $panel.Hide();Show-ControlPanel
                if($panel.Location -ne $originalPoint -or -not $panel.Visible){throw 'Panel position retention failed'}
                $panel.Hide()
                $mouse=New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left,1,0,0,0)
                $method=$tray.GetType().GetMethod('OnMouseClick',[Reflection.BindingFlags]'Instance,NonPublic')
                [void]$method.Invoke($tray.PSObject.BaseObject,[object[]]@($mouse.PSObject.BaseObject))
                if(-not $panel.Visible -or $menu.Visible -or $panel.Location -ne $originalPoint){throw 'Left click must reveal the stationary panel, not a popup menu'}
                if($Preview -eq 'api'){Show-ApiManager}elseif($ScreenshotPath){Save-UiScreenshot $panel $ScreenshotPath}
            }else{
            $menu.Show(50,50);[Windows.Forms.Application]::DoEvents()
            if($ScreenshotPath){$bmp=New-Object Drawing.Bitmap($menu.Width,$menu.Height);try{$menu.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$menu.Width,$menu.Height)));$bmp.Save($ScreenshotPath)}finally{$bmp.Dispose()}}
            $menu.Close()
            }
        }else{if($Action -in @('panel','configure')){Show-ControlPanel};if($LifecycleObserver){$LifecycleObserver.Invoke('ready-'+$Action)};if($Action -eq 'configure'){Show-ApiManager};[Windows.Forms.Application]::Run($context)}
    }finally{if($panelTimer){$panelTimer.Stop();$panelTimer.Dispose()};if($panelEvent){$panelEvent.Dispose()};if($configureEvent){$configureEvent.Dispose()};if($panel){$panel.Dispose()};if($tray){$tray.Visible=$false;$tray.Dispose()};if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}catch{if($LifecycleObserver){$LifecycleObserver.Invoke('failed-'+$_.Exception.GetType().FullName)};if($Action -eq 'status' -or $SmokeTest){throw};Show-Error $_;exit 1}
