param(
    [string]$ConfigPath = '',
    [ValidateSet('tray','panel','official','api','status')][string]$Action = 'tray',
    [switch]$SmokeTest,
    [string]$ScreenshotPath
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\Instances.ps1"
[Windows.Forms.Application]::EnableVisualStyles()
function Show-Error($ErrorRecord) {[void][Windows.Forms.MessageBox]::Show($ErrorRecord.Exception.Message,'Codex 双环境','OK','Warning')}
try {
    if(-not $ConfigPath){$ConfigPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'instances.local.json';if(-not (Test-Path -LiteralPath $ConfigPath)){$ConfigPath=Join-Path $env:LOCALAPPDATA 'CodexDualController\instances.local.json'}}
    $config=Read-ControllerConfig $ConfigPath
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
            $label=if($instance.role -eq 'official'){'官方版'}else{'API 版'}
            $answer=[Windows.Forms.MessageBox]::Show("退出$label？无法可靠查询任务状态。请先在该实例中确认没有正在执行的任务；关闭窗口也可能仅隐藏到原生托盘。",'确认退出','YesNo','Warning','Button2')
            if($answer -ne 'Yes'){return}
            $before=Get-ProcessSnapshot;$owned=@(Get-OwnedDesktopChildren $process $before)
            Request-InstanceClose $instance $process
            $alive=$true
            for($i=0;$i -lt 20;$i++) {
                Start-Sleep -Milliseconds 400
                $alive=@(Get-ProcessSnapshot | Where-Object {Test-ProcessIdentity $process $_}).Count -gt 0
                if(-not $alive){break}
            }
            if($alive) {
                $answer=[Windows.Forms.MessageBox]::Show("$label 仍在后台运行。是否强制结束已核验的桌面进程？可能中断任务和丢失未保存内容。不会结束任务启动的服务器、编辑器或无法确认归属的进程。",'正常退出未完成','YesNo','Warning','Button2')
                if($answer -eq 'Yes'){ $owned=@(Stop-InstanceForced $instance $process -UserConfirmed);Start-Sleep -Milliseconds 500 }
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
    $panel=$null;$panelEvent=$null;$panelTimer=$null;$script:quittingController=$false
    $mutex=New-Object Threading.Mutex($false,('Local\CodexDual.Controller.'+$sid));$held=$false
    try{try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){if($SmokeTest){throw 'Controller already running'}
            try{$otherEvent=[Threading.EventWaitHandle]::OpenExisting($eventName);try{[void]$otherEvent.Set()}finally{$otherEvent.Dispose()};return}catch{}
            [void][Windows.Forms.MessageBox]::Show('其他配置的控制器已经运行，请先从其托盘退出控制器再打开此入口。Codex 不需要退出。','Codex 双环境');return
        }
        $context=New-Object Windows.Forms.ApplicationContext
        $tray=New-Object Windows.Forms.NotifyIcon
        $iconPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\controller.ico'
        if(Test-Path -LiteralPath $iconPath){$tray.Icon=New-Object Drawing.Icon($iconPath)}else{$tray.Icon=[Drawing.SystemIcons]::Application}
        $controllerLabel=[string](Get-ObjectValue $config 'displayName' 'Codex 双环境')
        if($controllerLabel.Length -gt 63){$controllerLabel=$controllerLabel.Substring(0,63)}
        $tray.Text=$controllerLabel;$menu=New-Object Windows.Forms.ContextMenuStrip
        [void]$menu.Items.Add($controllerLabel);$menu.Items[0].Enabled=$false
        $labels=@{}
        foreach($role in @('official','api')){$item=$menu.Items.Add('状态读取中');$item.Enabled=$false;$labels[$role]=$item}
        [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        foreach($role in @('official','api')){
            $entry=$menu.Items.Add($(if($role -eq 'official'){'启动或显示官方版'}else{'启动或显示 API 版'}));$entry.Tag=$role
            $entry.Add_Click({param($sender,$eventArgs) try{$sender.Owner.Close();[Windows.Forms.Application]::DoEvents();Open-Instance @($config.instances | Where-Object {$_.role -eq $sender.Tag})[0]}catch{Show-Error $_}})
        }
        [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        foreach($role in @('official','api')){
            $entry=$menu.Items.Add($(if($role -eq 'official'){'退出官方版…'}else{'退出 API 版…'}));$entry.Tag=$role
            $entry.Add_Click({param($sender,$eventArgs) try{Close-Instance @($config.instances | Where-Object {$_.role -eq $sender.Tag})[0]}catch{Show-Error $_}})
        }
        [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        $exitItem=$menu.Items.Add('退出控制器');$exitItem.Add_Click({$script:quittingController=$true;$context.ExitThread()})
        $menu.Add_Opening({
            foreach($instance in $config.instances){$prefix=if($instance.role -eq 'official'){'官方版'}else{'API 版'}
                try{$s=Get-InstanceStatus $config $instance;$labels[$instance.role].Text=$prefix+'：'+$s.Reason}
                catch{$labels[$instance.role].Text=$prefix+'：状态未知';$labels[$instance.role].ToolTipText=$_.Exception.Message}
            }
        })
        $tray.ContextMenuStrip=$menu;$tray.Visible=$true
        $tray.Add_MouseClick({param($sender,$eventArgs) if($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left){$menu.Show([Windows.Forms.Cursor]::Position)}})
        $panel=New-Object Windows.Forms.Form
        $panel.Text=$controllerLabel;$panel.ClientSize=New-Object Drawing.Size(440,285)
        $panel.FormBorderStyle='FixedSingle';$panel.MaximizeBox=$false;$panel.StartPosition='CenterScreen'
        $panel.Icon=$tray.Icon;$panel.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
        $panel.BackColor=[Drawing.Color]::White
        $heading=New-Object Windows.Forms.Label;$heading.Text='选择要使用的 Codex';$heading.SetBounds(22,18,390,30);$heading.Font=New-Object Drawing.Font('Microsoft YaHei UI',15,[Drawing.FontStyle]::Bold);$panel.Controls.Add($heading)
        $panelLabels=@{}
        foreach($role in @('official','api')){
            $x=if($role -eq 'official'){22}else{230}
            $button=New-Object Windows.Forms.Button;$button.Text=if($role -eq 'official'){'打开官方版'}else{'打开 API 版'};$button.Tag=$role;$button.SetBounds($x,68,188,58)
            $button.Add_Click({param($sender,$e)try{$panel.UseWaitCursor=$true;Open-Instance @($config.instances|Where-Object {$_.role -eq $sender.Tag})[0]}catch{Show-Error $_}finally{$panel.UseWaitCursor=$false}});$panel.Controls.Add($button)
            $label=New-Object Windows.Forms.Label;$label.SetBounds($x,136,188,25);$label.Text='读取状态…';$panel.Controls.Add($label);$panelLabels[$role]=$label
            $closeButton=New-Object Windows.Forms.Button;$closeButton.Text='退出此实例…';$closeButton.Tag=$role;$closeButton.SetBounds($x,169,188,32)
            $closeButton.Add_Click({param($sender,$e)try{Close-Instance @($config.instances|Where-Object {$_.role -eq $sender.Tag})[0];Update-PanelStatus}catch{Show-Error $_}});$panel.Controls.Add($closeButton)
        }
        $hint=New-Object Windows.Forms.Label;$hint.Text='关闭面板会收起到托盘，Codex 继续运行。';$hint.SetBounds(22,219,400,24);$panel.Controls.Add($hint)
        $refresh=New-Object Windows.Forms.Button;$refresh.Text='刷新状态';$refresh.SetBounds(22,247,130,28);$refresh.Add_Click({Update-PanelStatus});$panel.Controls.Add($refresh)
        $quit=New-Object Windows.Forms.Button;$quit.Text='退出控制器';$quit.SetBounds(288,247,130,28);$quit.Add_Click({$script:quittingController=$true;$context.ExitThread()});$panel.Controls.Add($quit)
        function Update-PanelStatus {
            foreach($instance in $config.instances){try{$s=Get-InstanceStatus $config $instance;$panelLabels[$instance.role].Text=$s.Reason}catch{$panelLabels[$instance.role].Text='状态未知'}}
        }
        function Show-ControlPanel {if($panel.WindowState -eq 'Minimized'){$panel.WindowState='Normal'};$panel.Show();$panel.Activate();Update-PanelStatus}
        $panel.Add_FormClosing({param($sender,$e)if(-not $script:quittingController -and $e.CloseReason -eq 'UserClosing'){$e.Cancel=$true;$panel.Hide()}})
        $openPanelItem=New-Object Windows.Forms.ToolStripMenuItem('打开控制面板');$openPanelItem.Add_Click({$menu.Close();Show-ControlPanel});$menu.Items.Insert(1,$openPanelItem)
        $panelEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,$eventName)
        $panelTimer=New-Object Windows.Forms.Timer;$panelTimer.Interval=250;$panelTimer.Add_Tick({if($panelEvent.WaitOne(0)){Show-ControlPanel}});$panelTimer.Start()
        if($SmokeTest){
            if($Action -eq 'panel'){
                Show-ControlPanel;[Windows.Forms.Application]::DoEvents()
                if($ScreenshotPath){$bmp=New-Object Drawing.Bitmap($panel.Width,$panel.Height);try{$panel.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$panel.Width,$panel.Height)));$bmp.Save($ScreenshotPath)}finally{$bmp.Dispose()}}
            }else{
            $menu.Show(50,50);[Windows.Forms.Application]::DoEvents()
            if($ScreenshotPath){$bmp=New-Object Drawing.Bitmap($menu.Width,$menu.Height);try{$menu.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$menu.Width,$menu.Height)));$bmp.Save($ScreenshotPath)}finally{$bmp.Dispose()}}
            $menu.Close()
            }
        }else{if($Action -eq 'panel'){Show-ControlPanel};[Windows.Forms.Application]::Run($context)}
    }finally{if($panelTimer){$panelTimer.Stop();$panelTimer.Dispose()};if($panelEvent){$panelEvent.Dispose()};if($panel){$panel.Dispose()};if($tray){$tray.Visible=$false;$tray.Dispose()};if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}catch{if($Action -eq 'status' -or $SmokeTest){throw};Show-Error $_;exit 1}
