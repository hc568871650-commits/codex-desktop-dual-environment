. "$PSScriptRoot\CardLayout.ps1"
if(-not ('CodexDual.CompletionCard' -as [type])){Add-Type -Path "$PSScriptRoot\CompletionCard.cs" -ReferencedAssemblies System.Windows.Forms,System.Drawing -WarningAction SilentlyContinue}

. "$PSScriptRoot\CompletionNavigation.ps1"
$script:navigationFeedback=$null
function Read-CompletionSettings($Config) {
    $path=Join-Path $Config.stateDirectory 'notifications\settings.local.json';Assert-NoReparsePoint $path
    if(Test-Path -LiteralPath $path){
        $value=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if($value.schema -ne 1 -or $value.enabled -isnot [bool] -or $value.epoch -notmatch '^[a-f0-9]{32}$'){throw '独立通知设置无法读取，请检查通知设置文件。'}
        $duration=Get-ObjectValue $value 'displaySeconds' 15
        $fade=Get-ObjectValue $value 'fadeEnabled' $false
        if($duration -isnot [int] -or $duration -lt 0 -or $duration -gt 3600 -or $fade -isnot [bool]){throw '通知显示设置无效，请检查通知设置文件。'}
        $value|Add-Member NoteProperty displaySeconds $duration -Force
        $value|Add-Member NoteProperty fadeEnabled $fade -Force
        return $value
    }
    return [pscustomobject]@{schema=1;enabled=$true;epoch=[Guid]::NewGuid().ToString('N');displaySeconds=15;fadeEnabled=$false}
}
function Save-CompletionSettings($Config,$Settings){
    $path=Join-Path $Config.stateDirectory 'notifications\settings.local.json';Assert-NoReparsePoint $path
    [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent));Write-AtomicText $path ($Settings|ConvertTo-Json -Compress)
}
function Initialize-CompletionNotifications {
    $script:completionCards=New-Object 'Collections.Generic.List[Windows.Forms.Form]'
    $script:completionHistory=@()
    $script:completionWorker=$null;$script:completionRunId='';$script:completionSeen=@{};$script:completionArea=$null
    $script:completionRestartPending=$false
    $script:retiringCompletionWorkers=New-Object 'Collections.Generic.List[object]'
    $script:completionRoot=Join-Path $config.stateDirectory 'notifications'
    $script:completionSettings=Read-CompletionSettings $config
    if(-not $SmokeTest){Save-CompletionSettings $config $script:completionSettings;if($script:completionSettings.enabled){Start-CompletionWorker}}
}
function Start-CompletionWorker {
    if($SmokeTest -or $script:retiringCompletionWorkers.Count -or ($script:completionWorker -and -not $script:completionWorker.HasExited)){return}
    if($script:completionWorker){$script:completionWorker.Dispose()}
    $script:completionRunId=[Guid]::NewGuid().ToString('N')
    $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe";$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    foreach($name in @($info.EnvironmentVariables.Keys)){if($name -match '^(CODEX_|OPENAI_|CHATGPT_|ELECTRON_)' -or $name -in @('PSModulePath','CUSTOM_API_KEY','NODE_OPTIONS')){$info.EnvironmentVariables.Remove($name)}}
    $info.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'NotificationWorker.ps1')+'" -ConfigPath "'+[IO.Path]::GetFullPath($ConfigPath)+'" -StateDirectory "'+$script:completionRoot+'" -Epoch '+$script:completionSettings.epoch+' -RunId '+$script:completionRunId+' -ParentProcessId '+$PID+' -ParentStarted '+[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks
    $script:completionWorker=[Diagnostics.Process]::Start($info)
}
function Stop-CompletionWorker {
    if(-not $script:completionWorker){return}
    $worker=$script:completionWorker;$runId=$script:completionRunId
    $script:completionWorker=$null;$script:completionRunId=''
    try{
        if(-not $worker.HasExited){
            $stop=Join-Path $script:completionRoot ('stop-'+$runId+'.request');Assert-NoReparsePoint $stop
            Write-AtomicText $stop ''
            $script:retiringCompletionWorkers.Add([pscustomobject]@{process=$worker;deadline=[DateTime]::UtcNow.AddSeconds(4)})
        }else{$worker.Dispose()}
    }catch{
        # A failed stop request still leaves this owned process scheduled for cleanup.
        $script:retiringCompletionWorkers.Add([pscustomobject]@{process=$worker;deadline=[DateTime]::UtcNow.AddSeconds(4)})
        throw
    }
}
function Update-RetiringCompletionWorkers {
    for($n=$script:retiringCompletionWorkers.Count-1;$n -ge 0;$n--){
        $item=$script:retiringCompletionWorkers[$n];$worker=$item.process
        if(-not $worker.HasExited -and [DateTime]::UtcNow -ge $item.deadline){
            try{$worker.Kill()}catch [InvalidOperationException] { }
        }
        if($worker.HasExited){$worker.Dispose();$script:retiringCompletionWorkers.RemoveAt($n)}
    }
}
function Update-CompletionCardLayout {
    for($n=$script:completionCards.Count-1;$n -ge 0;$n--){if($script:completionCards[$n].IsDisposed){$script:completionCards.RemoveAt($n)}}
    $cards=@($script:completionCards.ToArray())
    if((Get-Variable questionNotice -Scope Script -ErrorAction SilentlyContinue) -and $script:questionNotice -and -not $script:questionNotice.IsDisposed -and $script:questionNotice.Visible){$cards+=,$script:questionNotice}
    if($cards.Count){if(-not $script:completionArea){$script:completionArea=[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea};Set-NotificationCardLayout $cards $script:completionArea}else{$script:completionArea=$null}
}
function Close-CompletionCards {foreach($card in @($script:completionCards.ToArray())){$card.Close();$card.Dispose()};$script:completionCards.Clear();$script:completionArea=$null;if((Get-Variable questionNotice -Scope Script -ErrorAction SilentlyContinue) -and $script:questionNotice -and -not $script:questionNotice.IsDisposed){$script:questionNotice.Close()};if($script:navigationFeedback -and -not $script:navigationFeedback.IsDisposed){$script:navigationFeedback.Close()}}
function Test-CompletionSnoozed {
    $until=[string](Get-ObjectValue $script:completionSettings 'snoozedUntilUtc' '')
    if(-not $until){return $false}
    $stamp=[DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParse($until,[ref]$stamp) -and $stamp -gt [DateTimeOffset]::UtcNow
}
function Set-CompletionSnooze([ValidateSet(0,15,60)][int]$Minutes) {
    $until=if($Minutes){[DateTimeOffset]::UtcNow.AddMinutes($Minutes).ToString('o')}else{''}
    $script:completionSettings|Add-Member NoteProperty snoozedUntilUtc $until -Force
    Save-CompletionSettings $config $script:completionSettings
    if($Minutes){Close-CompletionCards}
}
function Set-CompletionDisplaySettings([int]$Seconds,[bool]$FadeEnabled) {
    if($Seconds -lt 0 -or $Seconds -gt 3600){throw '显示时间应为 1–3600 秒，或选择常驻。'}
    $next=[pscustomobject]@{}
    foreach($property in $script:completionSettings.PSObject.Properties){$next|Add-Member NoteProperty $property.Name $property.Value}
    $next.displaySeconds=$Seconds;$next.fadeEnabled=$FadeEnabled
    Save-CompletionSettings $config $next
    $script:completionSettings=$next
    foreach($card in @($script:completionCards.ToArray())){$card.SetDisplaySettings($Seconds*1000,$FadeEnabled)}
    if((Get-Variable questionNotice -Scope Script -ErrorAction SilentlyContinue) -and $script:questionNotice -and -not $script:questionNotice.IsDisposed){$script:questionNotice.SetDisplaySettings($Seconds*1000,$FadeEnabled)}
}
function Open-CompletionTarget($Instance,[string]$ThreadId) {
    try{Start-PanelOpen @($Instance.role) $(if(Test-TaskIdentifier $ThreadId){$ThreadId}else{''}) -FromNotification}
    catch{Show-TaskNavigationFeedback $_.Exception.Message}
}
function Show-TaskNavigationFeedback([string]$Message) {
    if((Get-Variable navigationFeedback -Scope Script -ErrorAction SilentlyContinue) -and $script:navigationFeedback -and -not $script:navigationFeedback.IsDisposed){$script:navigationFeedback.Dispose()}
    $card=New-Object CodexDual.CompletionCard;$script:navigationFeedback=$card
    $card.Text='返回任务';$card.ShowInTaskbar=$false;$card.TopMost=$true;$card.StartPosition='Manual';$card.ClientSize=New-Object Drawing.Size(420,166);$card.Font=$panel.Font
    $heading=New-UiLabel $card '返回任务' 20 14 365 26;$heading.Font=New-Object Drawing.Font($panel.Font.FontFamily,11,[Drawing.FontStyle]::Bold)
    $body=New-UiLabel $card $Message 20 46 377 66;$body.AutoEllipsis=$true
    [void](New-UiButton $card '知道了' 280 120 117 {param($sender,$e) $sender.FindForm().Close()})
    if((Get-Variable completionReady -Scope Script -ErrorAction SilentlyContinue) -and $script:completionReady){$card.SetDisplaySettings(([int]$script:completionSettings.displaySeconds*1000),[bool]$script:completionSettings.fadeEnabled)}
    $area=[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $card.Location=New-Object Drawing.Point(($area.Right-$card.Width-20),($area.Bottom-$card.Height-20));Set-UiTheme $card;$card.Show()
}
function Show-CompletionCard($Instance,$Event=$null) {
    $preview=[bool](Get-ObjectValue $Event 'preview' $false)
    $cardTag=if($preview){'preview'}else{$Instance.id}
    foreach($old in @($script:completionCards.ToArray())){if($old.Tag -eq $cardTag){$old.Close();$old.Dispose()}}
    if(-not $script:completionArea){$script:completionArea=[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea}
    $card=New-Object CodexDual.CompletionCard;$card.Text=(Get-InstanceDisplayName $Instance $script:preferences)+$(if($preview){' · 通知预览'}else{' · 任务完成'});$card.Tag=$cardTag
    $card.SetDisplaySettings(([int]$script:completionSettings.displaySeconds*1000),([bool]$script:completionSettings.fadeEnabled))
    if($preview){$card.Name='CompletionPreview'}
    $card.ClientSize=New-Object Drawing.Size(420,192);$card.ShowInTaskbar=$false;$card.TopMost=$true;$card.Font=$panel.Font;$card.StartPosition='Manual'
    $card.ThreadId=[string](Get-ObjectValue $Event 'threadId' '')
    $card.Add_FormClosed({param($sender,$e) [void]$script:completionCards.Remove($sender);Update-CompletionCardLayout})
    $header=New-UiLabel $card ('Codex · '+(Get-InstanceDisplayName $Instance $script:preferences)) 20 16 325 24;$header.AutoEllipsis=$true
    $title=[string](Get-ObjectValue $Event 'title' '任务已完成');if(-not $title){$title='任务已完成'}
    $title=($title -replace '[\p{Cc}\p{Cf}]',' ').Trim();if($title.Length -gt 100){$title=$title.Substring(0,99)+'…'}
    $heading=New-UiLabel $card $title 20 49 380 29;$heading.AutoEllipsis=$true;$heading.Font=New-Object Drawing.Font($panel.Font.FontFamily,12,[Drawing.FontStyle]::Bold)
    $description=New-UiLabel $card $(if($preview){'这是 API 端任务完成通知的预览。'}else{'任务已完成，点击查看结果。'}) 20 87 380 25
    $openAction={
        param($sender,$e)
        if($sender.FindForm().Name -eq 'CompletionPreview'){$sender.FindForm().Close();return}
        if($script:uiBusy -or $script:openBusy){return}
        $owner=$sender.FindForm();$id=[string]$owner.Tag;$threadId=$owner.ThreadId;$target=@($config.instances|Where-Object {$_.id -eq $id})
        if($target.Count -ne 1){return};$owner.Close();Invoke-PanelAction {Open-CompletionTarget $target[0] $threadId}
    }
    $button=New-UiButton $card $(if($preview){'关闭预览'}elseif(Test-TaskIdentifier $card.ThreadId){'查看任务'}else{'打开对应端'}) 18 138 $(if($preview){384}else{120}) $openAction;$button.Primary=$true
    $heading.Cursor='Hand';$description.Cursor='Hand';$heading.Add_Click($openAction);$description.Add_Click($openAction)
    if(-not $preview){
        [void](New-UiButton $card '关闭提示' 148 138 112 {param($sender,$e) $sender.FindForm().Close()})
        [void](New-UiButton $card '暂停提醒…' 270 138 132 {
            param($sender,$e)
            $pause=New-Object CodexDual.QuietMenu
            foreach($minutes in @(15,60)){$item=$pause.Items.Add(('暂停 '+$minutes+' 分钟'));$item.Tag=$minutes;$item.Add_Click({param($sender,$e) Set-CompletionSnooze ([int]$sender.Tag)})}
            if($sender.ContextMenuStrip){$sender.ContextMenuStrip.Dispose()};$sender.ContextMenuStrip=$pause
            $owner=$sender.FindForm();$owner.PauseDismissal=$true
            $pause.Add_Closed({param($menu,$args) if(-not $owner.IsDisposed){$owner.PauseDismissal=$false}}.GetNewClosure())
            $pause.Show($sender,(New-Object Drawing.Point(0,$sender.Height)))
        })
    }
    $dismiss=New-UiButton $card '×' 366 10 38 {param($sender,$e) $sender.FindForm().Close()};$dismiss.Quiet=$true;$dismiss.AccessibleName='关闭提示'
    $header.Name='Muted';$description.Name='Muted'
    Set-UiTheme $card
    $header.ForeColor=[CodexDual.AppTheme]::Muted;$description.ForeColor=$header.ForeColor
    $script:completionCards.Add($card);Update-CompletionCardLayout;$card.Show()
}
function Show-CompletionPreview {
    $api=@($config.instances|Where-Object {$_.role -eq 'api'})
    if($api.Count -ne 1){Set-UiMessage '未找到 API 端，无法预览通知。';return}
    Show-CompletionCard $api[0] ([pscustomobject]@{preview=$true;title='通知预览 · API 端任务已完成'})
}
function Set-CompletionNotificationsEnabled([bool]$Enabled) {
    $nextSettings=[pscustomobject]@{}
    foreach($property in $script:completionSettings.PSObject.Properties){
        $nextSettings|Add-Member NoteProperty $property.Name $property.Value
    }
    $nextSettings.enabled=$Enabled
    # Every toggle begins a fresh baseline; events from an older epoch stay silent.
    $nextSettings.epoch=[Guid]::NewGuid().ToString('N')
    $nextSettings|Add-Member NoteProperty snoozedUntilUtc '' -Force
    Save-CompletionSettings $config $nextSettings
    $script:completionSettings=$nextSettings
    $script:completionRestartPending=$false
    Stop-CompletionWorker;Close-CompletionCards
    if($Enabled){
        if($script:retiringCompletionWorkers.Count){$script:completionRestartPending=$true}
        else{
            try{Start-CompletionWorker}
            catch{Set-UiMessage '独立通知监听启动失败。可关闭后重新开启通知；两端任务不受影响。'}
        }
    }
}
function Get-CompletionStatusText {
    if(-not $script:completionSettings.enabled){return '已关闭'}
    if($script:completionRestartPending -or $script:retiringCompletionWorkers.Count){return '正在切换'}
    if(($script:completionWorker -and $script:completionWorker.HasExited) -or (-not $SmokeTest -and -not $script:completionWorker)){return '监听已停止'}
    if(Test-CompletionSnoozed){return ('暂停至'+[DateTimeOffset]::Parse([string]$script:completionSettings.snoozedUntilUtc).ToLocalTime().ToString('HH:mm'))}
    return '已开启'
}
function Update-CompletionNotifications {
    Update-RetiringCompletionWorkers
    if($script:completionRestartPending -and -not $script:retiringCompletionWorkers.Count){
        $script:completionRestartPending=$false
        if($script:completionSettings.enabled){
            try{Start-CompletionWorker}
            catch{Set-UiMessage '独立通知监听启动失败。可关闭后重新开启通知；两端任务不受影响。';return}
        }
    }
    if($SmokeTest -or -not $script:completionSettings.enabled){return}
    if($script:completionWorker -and $script:completionWorker.HasExited){
        Set-UiMessage '独立通知监听已停止。可从托盘关闭后重新开启通知；两端任务不受影响。';return
    }
    $inbox=Join-Path $script:completionRoot 'inbox'
    if(-not (Test-Path -LiteralPath $inbox)){return}
    Assert-NoReparsePoint $inbox
    foreach($file in @(Get-ChildItem -LiteralPath $inbox -Filter '*.local.json' -File|Sort-Object LastWriteTimeUtc|Select-Object -First 32)){
        $path=$file.FullName
        try{
            Assert-NoReparsePoint $path
            if($file.Length -gt 4096){Remove-Item -LiteralPath $path -Force;continue}
            $event=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
            $instance=@($config.instances|Where-Object {$_.id -eq $event.instanceId})
            if($event.schema -ne 1 -or $event.epoch -ne $script:completionSettings.epoch -or $instance.Count -ne 1 -or $event.eventId -notmatch '^[a-f0-9]{32}$' -or -not (Test-TaskIdentifier ([string](Get-ObjectValue $event 'threadId' ''))) -or -not (Test-TaskIdentifier ([string](Get-ObjectValue $event 'turnId' '')))){
                Remove-Item -LiteralPath $path -Force;continue
            }
            # Immutable, unique event files avoid racing a producer's atomic replace.
            Remove-Item -LiteralPath $path -Force
            $script:completionHistory=@($event)+@($script:completionHistory|Where-Object {$_.instanceId -ne $event.instanceId -or $_.threadId -ne $event.threadId}|Select-Object -First 19)
            if(-not (Test-CompletionSnoozed)){Show-CompletionCard $instance[0] $event}
        }catch{Set-UiMessage '一条独立通知无法读取，已跳过；两端任务不受影响。'}
    }
}
function Dispose-CompletionNotifications {
    $script:completionRestartPending=$false
    try{Stop-CompletionWorker}finally{
        $deadline=[DateTime]::UtcNow.AddSeconds(4)
        foreach($item in @($script:retiringCompletionWorkers.ToArray())){
            $worker=$item.process
            try{
                if(-not $worker.HasExited){[void]$worker.WaitForExit([Math]::Max(0,[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds))}
                if(-not $worker.HasExited){$worker.Kill();[void]$worker.WaitForExit(2000)}
            }finally{$worker.Dispose()}
        }
        $script:retiringCompletionWorkers.Clear();Close-CompletionCards
    }
}
