param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [ValidateRange(30,900)][int]$DurationSeconds=300,
    [ValidateSet('Card','Balloon')][string]$DisplayMode='Card'
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\..\src\Instances.ps1"
. "$PSScriptRoot\CompletionReader.ps1"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\CardLayout.ps1"
[Windows.Forms.Application]::EnableVisualStyles()
$config=Read-ControllerConfig $ConfigPath
$output=Get-FullDirectory $OutputDirectory;Assert-NoReparsePoint $output
[void][IO.Directory]::CreateDirectory($output)
$log=Join-Path $output 'events.jsonl'
if(Test-Path -LiteralPath $log){throw '实验目录已有记录，请使用新目录。'}
$configHash=(Get-FileHash -LiteralPath $ConfigPath).Hash
$icons=@{};$cursors=@{};$fixturePaths=@{};$instances=@{};$processes=@{}
$script:cards=@{}
$script:cardOrder=New-Object 'Collections.Generic.List[Windows.Forms.Form]'
$watchCursors=New-Object 'Collections.Generic.List[object]'
$watchFiles=@{};$script:busy=$false;$script:notifications=0;$script:clicks=0
$timer=$null;$form=$null
function Write-ExperimentEvent([string]$Kind,[string]$Role,$Details) {
    $entry=[ordered]@{utc=[DateTime]::UtcNow.ToString('o');kind=$Kind;role=$Role;details=$Details}
    [IO.File]::AppendAllText($log,($entry|ConvertTo-Json -Depth 5 -Compress)+"`r`n",(New-Object Text.UTF8Encoding($false)))
}
function Add-FixtureCompletion([string]$Role) {
    $line=@{type='event_msg';payload=@{type='task_complete';turn_id=[Guid]::NewGuid().ToString();last_agent_message='SIMULATED-PRIVATE-CONTENT-NOT-FOR-NOTIFICATION'}}|ConvertTo-Json -Compress
    [IO.File]::AppendAllText($fixturePaths[$Role],$line+"`n",(New-Object Text.UTF8Encoding($false)))
}
function Update-ExperimentCardLayout {
    for($index=$script:cardOrder.Count-1;$index -ge 0;$index--){
        if($script:cardOrder[$index].IsDisposed){$script:cardOrder.RemoveAt($index)}
    }
    if($null -ne $form -and -not $form.IsDisposed){Set-NotificationCardLayout @($script:cardOrder.ToArray()) ([Windows.Forms.Screen]::FromControl($form).WorkingArea)}
}
function Open-ExperimentTarget([string]$Role) {
    if($script:busy){return}
    $script:busy=$true
    try {
        $script:clicks++;Write-ExperimentEvent 'clicked' $Role @{}
        $instance=$instances[$Role]
        # This experiment never starts a stopped environment and never writes its configuration.
        $status=Get-InstanceStatus $config $instance
        if($status.State -ne 'Running'){throw '实验只找回已运行的目标。'}
        [void](Request-NativeInstanceActivation $instance $status.Process)
        $windows=@(Get-InstanceWindows $instance $status.Process|Where-Object {$_.Visible})
        if($windows.Count -ne 1){throw '实验要求目标有且只有一个可见主窗口。'}
        $focused=Show-InstanceWindow $instance $status.Process $windows[0].Handle
        $foreground=[CodexDual.Native]::Foreground()
        $matched=$foreground -eq $windows[0].Handle
        Write-ExperimentEvent 'routed' $Role @{targetPid=$status.Process.Id;targetStarted=$status.Process.Started;targetHandle=$windows[0].Handle;foregroundHandle=$foreground;foregroundMatches=$matched;focusAccepted=$focused}
        $statusLabel.Text=$(if($matched){'已核验：通知进入 '+$Role+' 对应端。'}else{'目标已显示，但 Windows 未允许切换前台。'})
    }catch{
        Write-ExperimentEvent 'route-failed' $Role @{exception=$_.Exception.GetType().FullName}
        $statusLabel.Text='目标未能确认，已停止跳转；未切换到另一端。'
    }finally{$script:busy=$false}
}
function Send-ExperimentNotification($Completion,[bool]$Simulated) {
    $target=@($config.instances|Where-Object {$_.id -eq $Completion.InstanceId})
    if($target.Count -ne 1){throw '完成事件的实例归属无效。'}
    $role=$target[0].role;$label=if($role -eq 'api'){'API 端'}else{'官方端'}
    $script:notifications++
    $title=$label+$(if($Simulated){' · 模拟任务完成'}else{' · 任务完成（实验）'})
    # Each icon is permanently bound to one role. No mutable global "last role".
    if($DisplayMode -eq 'Balloon'){
        $icons[$role].ShowBalloonTip(30000,$title,'点击找回对应窗口。实验不会发送模型请求。',[Windows.Forms.ToolTipIcon]::Info)
    }else{
        if($script:cards.ContainsKey($role)){$script:cards[$role].Close();$script:cards[$role].Dispose()}
        $card=New-Object Windows.Forms.Form;$card.Text=$title;$card.Tag=$role;$card.ClientSize=New-Object Drawing.Size(410,140)
        $card.FormBorderStyle='FixedToolWindow';$card.ShowInTaskbar=$false;$card.TopMost=$true;$card.Font=$form.Font;$card.StartPosition='Manual'
        $card.Add_FormClosed({param($sender,$eventArgs) [void]$script:cardOrder.Remove($sender);Update-ExperimentCardLayout})
        $description=New-Object Windows.Forms.Label;$description.SetBounds(16,14,378,52)
        $description.Text=$(if($Simulated){'独立提示卡片实验：模拟完成事件，未请求模型。'}else{'检测到此环境的任务完成事件。'})+' 点击只找回对应端。';$card.Controls.Add($description)
        $open=New-Object Windows.Forms.Button;$open.SetBounds(16,84,210,36);$open.Text='打开 '+$label
        $open.Add_Click({param($sender,$eventArgs) $owner=$sender.FindForm();$targetRole=[string]$owner.Tag;$owner.Hide();Open-ExperimentTarget $targetRole;$owner.Close()});$card.Controls.Add($open)
        $dismiss=New-Object Windows.Forms.Button;$dismiss.Text='关闭提示';$dismiss.SetBounds(240,84,152,36);$dismiss.Add_Click({param($sender,$eventArgs) $sender.FindForm().Close()});$card.Controls.Add($dismiss)
        $script:cards[$role]=$card;$script:cardOrder.Add($card);Update-ExperimentCardLayout;$card.Show();Write-ExperimentEvent 'card-visible' $role @{x=$card.Left;y=$card.Top;visibleCards=$script:cardOrder.Count}
    }
    Write-ExperimentEvent 'notification-requested' $role @{mode=$DisplayMode;simulated=$Simulated;threadId=$Completion.ThreadId;turnId=$Completion.TurnId}
    $statusLabel.Text=$title+'，请点击提示。'
}
try {
    $form=New-Object Windows.Forms.Form;$form.Text='Codex 双开 · 通知实验';$form.ClientSize=New-Object Drawing.Size(580,230)
    $form.StartPosition='CenterScreen';$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10);$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
    $label=New-Object Windows.Forms.Label;$label.Text='隔离实验：'+$(if($DisplayMode -eq 'Card'){'独立卡片，不进入 Windows 通知中心。'}else{'系统托盘气泡。'});$label.SetBounds(20,18,540,28);$form.Controls.Add($label)
    $statusLabel=New-Object Windows.Forms.Label;$statusLabel.Text='等待模拟完成事件。';$statusLabel.SetBounds(20,126,540,54);$form.Controls.Add($statusLabel)
    $position=20
    foreach($instance in $config.instances){
        $role=$instance.role;$instances[$role]=$instance
        $status=Get-InstanceStatus $config $instance
        if($status.State -ne 'Running'){throw '请先正常打开两端再运行实验。'}
        $processes[$role]=$status.Process
        Write-ExperimentEvent 'baseline' $role @{pid=$status.Process.Id;started=$status.Process.Started}
        $path=Join-Path $output ($role+'-fixture.jsonl');$fixturePaths[$role]=$path
        $meta=@{type='session_meta';payload=@{id=[Guid]::NewGuid().ToString();source='vscode';originator='Codex Desktop'}}|ConvertTo-Json -Depth 5 -Compress
        [IO.File]::WriteAllText($path,$meta+"`n",(New-Object Text.UTF8Encoding($false)))
        Add-FixtureCompletion $role
        $cursors[$role]=New-CompletionCursor -Path $path -InstanceId $instance.id
        $icon=New-Object Windows.Forms.NotifyIcon;$icon.Icon=New-Object Drawing.Icon((Join-Path $PSScriptRoot ('..\..\assets\'+$role+'.ico')))
        $icon.Text='Codex 通知实验 · '+$role;$icon.Tag=$role;$icon.Visible=$true
        $icon.Add_BalloonTipClicked({param($sender,$eventArgs) Open-ExperimentTarget ([string]$sender.Tag)})
        $icon.Add_BalloonTipShown({param($sender,$eventArgs) Write-ExperimentEvent 'notification-shown' ([string]$sender.Tag) @{}})
        $icons[$role]=$icon
        $button=New-Object Windows.Forms.Button;$button.Text=$(if($role -eq 'api'){'模拟 API 端完成'}else{'模拟官方端完成'});$button.Tag=$role;$button.SetBounds($position,65,170,40)
        $button.Add_Click({param($sender,$eventArgs) Add-FixtureCompletion ([string]$sender.Tag)})
        $form.Controls.Add($button);$position+=184
    }
    $stop=New-Object Windows.Forms.Button;$stop.Text='停止实验';$stop.SetBounds(390,65,170,40);$stop.Add_Click({$form.Close()});$form.Controls.Add($stop)
    $watch=New-Object Windows.Forms.CheckBox;$watch.Text='只读监听今天最近的 Desktop 任务（不重放历史）';$watch.SetBounds(20,186,540,28);$form.Controls.Add($watch)
    $watch.Add_CheckedChanged({
        foreach($oldCursor in $watchCursors){Close-CompletionCursor $oldCursor};$watchCursors.Clear();$watchFiles.Clear()
        if($watch.Checked){
            foreach($instance in $config.instances){
                $day=Join-Path $instance.home ('sessions/'+[DateTime]::Now.ToString('yyyy/MM/dd'))
                if(Test-Path -LiteralPath $day){
                    Assert-NoReparsePoint $day
                    foreach($file in @(Get-ChildItem -LiteralPath $day -Filter '*.jsonl' -File|Sort-Object LastWriteTime -Descending|Select-Object -First 16)){
                        $candidate=New-CompletionCursor -Path $file.FullName -InstanceId $instance.id;if($candidate.Status -in @('Ready','AwaitingMeta')){$watchCursors.Add($candidate);$watchFiles[$file.FullName]=$true}else{Close-CompletionCursor $candidate}
                    }
                }
            }
        }
        Write-ExperimentEvent 'watch-mode' '' @{enabled=$watch.Checked;files=$watchCursors.Count}
    })
    $end=[DateTime]::UtcNow.AddSeconds($DurationSeconds)
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=750
    $timer.Add_Tick({
        if([DateTime]::UtcNow -ge $end){$form.Close();return}
        if($script:busy){return}
        try {
            foreach($role in @('official','api')){$read=Read-NewCompletions $cursors[$role];if($read.Status -notin @('Ready','AwaitingMeta')){throw ('Reader stopped: '+$read.Status)};foreach($item in $read.Completions){Send-ExperimentNotification $item $true}}
            foreach($cursor in $watchCursors){$read=Read-NewCompletions $cursor;if($read.Status -notin @('Ready','AwaitingMeta')){throw ('Reader stopped: '+$read.Status)};foreach($item in $read.Completions){Send-ExperimentNotification $item $false}}
        }catch{Write-ExperimentEvent 'reader-failed' '' @{exception=$_.Exception.GetType().FullName};$statusLabel.Text='读取停止：请查看实验记录。';$timer.Stop()}
    })
    $timer.Start();Write-ExperimentEvent 'ready' '' @{duration=$DurationSeconds;historySkipped=$true}
    [Windows.Forms.Application]::Run($form)
}finally{
    if($timer){$timer.Stop();$timer.Dispose()};foreach($cursor in $cursors.Values){Close-CompletionCursor $cursor};foreach($cursor in $watchCursors){Close-CompletionCursor $cursor}
    foreach($icon in $icons.Values){$icon.Visible=$false;$icon.Icon.Dispose();$icon.Dispose()}
    foreach($card in $script:cards.Values){$card.Close();$card.Dispose()}
    if($form){$form.Dispose()}
    $preserved=@(foreach($role in $processes.Keys){[pscustomobject]@{role=$role;alive=(Test-ExpectedProcessAlive $processes[$role])}})
    Write-ExperimentEvent 'stopped' '' @{notifications=$script:notifications;clicks=$script:clicks;configUnchanged=((Get-FileHash -LiteralPath $ConfigPath).Hash -eq $configHash);originalProcesses=$preserved}
}
