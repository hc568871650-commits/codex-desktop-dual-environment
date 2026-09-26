. "$PSScriptRoot\CardLayout.ps1"
if(-not ('CodexDual.CompletionCard' -as [type])){Add-Type -Path "$PSScriptRoot\CompletionCard.cs" -ReferencedAssemblies System.Windows.Forms,System.Drawing -WarningAction SilentlyContinue}

. "$PSScriptRoot\CompletionNavigation.ps1"
function Read-CompletionSettings($Config) {
    $path=Join-Path $Config.stateDirectory 'notifications\settings.local.json';Assert-NoReparsePoint $path
    if(Test-Path -LiteralPath $path){
        $value=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if($value.schema -ne 1 -or $value.enabled -isnot [bool] -or $value.epoch -notmatch '^[a-f0-9]{32}$'){throw '独立通知设置无法读取，请检查通知设置文件。'}
        return $value
    }
    return [pscustomobject]@{schema=1;enabled=$true;epoch=[Guid]::NewGuid().ToString('N')}
}
function Save-CompletionSettings($Config,$Settings){
    $path=Join-Path $Config.stateDirectory 'notifications\settings.local.json';Assert-NoReparsePoint $path
    [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent));Write-AtomicText $path ($Settings|ConvertTo-Json -Compress)
}
function Initialize-CompletionNotifications {
    $script:completionCards=New-Object 'Collections.Generic.List[Windows.Forms.Form]'
    $script:completionHistory=@()
    $script:completionWorker=$null;$script:completionRunId='';$script:completionSeen=@{};$script:completionArea=$null
    $script:completionRoot=Join-Path $config.stateDirectory 'notifications'
    $script:completionSettings=Read-CompletionSettings $config
    if(-not $SmokeTest){Save-CompletionSettings $config $script:completionSettings;if($script:completionSettings.enabled){Start-CompletionWorker}}
}
function Start-CompletionWorker {
    if($SmokeTest -or ($script:completionWorker -and -not $script:completionWorker.HasExited)){return}
    if($script:completionWorker){$script:completionWorker.Dispose()}
    $script:completionRunId=[Guid]::NewGuid().ToString('N')
    $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe";$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    foreach($name in @($info.EnvironmentVariables.Keys)){if($name -match '^(CODEX_|OPENAI_|CHATGPT_|ELECTRON_)' -or $name -in @('PSModulePath','CUSTOM_API_KEY','NODE_OPTIONS')){$info.EnvironmentVariables.Remove($name)}}
    $info.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'NotificationWorker.ps1')+'" -ConfigPath "'+[IO.Path]::GetFullPath($ConfigPath)+'" -StateDirectory "'+$script:completionRoot+'" -Epoch '+$script:completionSettings.epoch+' -RunId '+$script:completionRunId+' -ParentProcessId '+$PID+' -ParentStarted '+[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks
    $script:completionWorker=[Diagnostics.Process]::Start($info)
}
function Stop-CompletionWorker {
    if(-not $script:completionWorker){return}
    try{
        if(-not $script:completionWorker.HasExited){
            $stop=Join-Path $script:completionRoot ('stop-'+$script:completionRunId+'.request');Assert-NoReparsePoint $stop
            Write-AtomicText $stop ''
            # Only this controller-created helper is terminated if it cannot stop promptly.
            if(-not $script:completionWorker.WaitForExit(4000)){$script:completionWorker.Kill();[void]$script:completionWorker.WaitForExit(2000)}
        }
    }finally{$script:completionWorker.Dispose();$script:completionWorker=$null}
}
function Update-CompletionCardLayout {
    for($n=$script:completionCards.Count-1;$n -ge 0;$n--){if($script:completionCards[$n].IsDisposed){$script:completionCards.RemoveAt($n)}}
    if($script:completionCards.Count){Set-NotificationCardLayout @($script:completionCards.ToArray()) $script:completionArea}else{$script:completionArea=$null}
}
function Close-CompletionCards {foreach($card in @($script:completionCards.ToArray())){$card.Close();$card.Dispose()};$script:completionCards.Clear();$script:completionArea=$null}
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
function Open-CompletionTarget($Instance,[string]$ThreadId) {
    if(Test-TaskIdentifier $ThreadId){Start-PanelOpen @($Instance.role) $ThreadId}
    else{Open-PanelInstance $Instance}
}
function Show-CompletionCard($Instance,$Event=$null) {
    foreach($old in @($script:completionCards.ToArray())){if($old.Tag -eq $Instance.id){$old.Close();$old.Dispose()}}
    if(-not $script:completionArea){$script:completionArea=[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea}
    $card=New-Object CodexDual.CompletionCard;$card.Text=(Get-InstanceDisplayName $Instance $script:preferences)+' · 任务完成';$card.Tag=$Instance.id
    $card.ClientSize=New-Object Drawing.Size(420,192);$card.ShowInTaskbar=$false;$card.TopMost=$true;$card.Font=$panel.Font;$card.StartPosition='Manual'
    $card.ThreadId=[string](Get-ObjectValue $Event 'threadId' '')
    $card.Add_FormClosed({param($sender,$e) [void]$script:completionCards.Remove($sender);Update-CompletionCardLayout})
    $header=New-UiLabel $card ('Codex · '+(Get-InstanceDisplayName $Instance $script:preferences)) 20 16 325 24;$header.AutoEllipsis=$true
    $title=[string](Get-ObjectValue $Event 'title' '任务已完成');if(-not $title){$title='任务已完成'}
    $title=($title -replace '[\p{Cc}\p{Cf}]',' ').Trim();if($title.Length -gt 100){$title=$title.Substring(0,99)+'…'}
    $heading=New-UiLabel $card $title 20 49 380 29;$heading.AutoEllipsis=$true;$heading.Font=New-Object Drawing.Font($panel.Font.FontFamily,12,[Drawing.FontStyle]::Bold)
    $description=New-UiLabel $card '任务已完成，点击查看结果。' 20 87 380 25
    $openAction={
        param($sender,$e)
        if($script:uiBusy -or $script:openBusy){return}
        $owner=$sender.FindForm();$id=[string]$owner.Tag;$threadId=$owner.ThreadId;$target=@($config.instances|Where-Object {$_.id -eq $id})
        if($target.Count -ne 1){return};$owner.Close();Invoke-PanelAction {Open-CompletionTarget $target[0] $threadId}
    }
    $button=New-UiButton $card $(if(Test-TaskIdentifier $card.ThreadId){'查看任务'}else{'打开对应端'}) 18 138 120 $openAction;$button.Primary=$true
    $heading.Cursor='Hand';$description.Cursor='Hand';$heading.Add_Click($openAction);$description.Add_Click($openAction)
    [void](New-UiButton $card '关闭提示' 148 138 112 {param($sender,$e) $sender.FindForm().Close()})
    [void](New-UiButton $card '暂停提醒…' 270 138 132 {
        param($sender,$e)
        $pause=New-Object CodexDual.QuietMenu
        foreach($minutes in @(15,60)){$item=$pause.Items.Add(('暂停 '+$minutes+' 分钟'));$item.Tag=$minutes;$item.Add_Click({param($sender,$e) Set-CompletionSnooze ([int]$sender.Tag)})}
        if($sender.ContextMenuStrip){$sender.ContextMenuStrip.Dispose()};$sender.ContextMenuStrip=$pause;$pause.Show($sender,(New-Object Drawing.Point(0,$sender.Height)))
    })
    $dismiss=New-UiButton $card '×' 366 10 38 {param($sender,$e) $sender.FindForm().Close()};$dismiss.Quiet=$true;$dismiss.AccessibleName='关闭提示'
    Set-UiTheme $card
    $header.ForeColor=[Drawing.ColorTranslator]::FromHtml('#737373');$description.ForeColor=$header.ForeColor
    $script:completionCards.Add($card);Update-CompletionCardLayout;$card.Show()
}
function Set-CompletionNotificationsEnabled([bool]$Enabled) {
    Stop-CompletionWorker;Close-CompletionCards
    $script:completionSettings.enabled=$Enabled
    # Re-enabling starts a fresh baseline; completions while disabled stay silent.
    $script:completionSettings.epoch=[Guid]::NewGuid().ToString('N')
    $script:completionSettings|Add-Member NoteProperty snoozedUntilUtc '' -Force
    Save-CompletionSettings $config $script:completionSettings
    if($Enabled){Start-CompletionWorker}
}
function Update-CompletionNotifications {
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
function Dispose-CompletionNotifications {Stop-CompletionWorker;Close-CompletionCards}
