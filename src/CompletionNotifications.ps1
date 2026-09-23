. "$PSScriptRoot\CardLayout.ps1"
if(-not ('CodexDual.CompletionCard' -as [type])){Add-Type -Path "$PSScriptRoot\CompletionCard.cs" -ReferencedAssemblies System.Windows.Forms,System.Drawing -WarningAction SilentlyContinue}

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
function Show-CompletionCard($Instance) {
    foreach($old in @($script:completionCards.ToArray())){if($old.Tag -eq $Instance.id){$old.Close();$old.Dispose()}}
    if(-not $script:completionArea){$script:completionArea=[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea}
    $card=New-Object CodexDual.CompletionCard;$card.Text=(Get-InstanceDisplayName $Instance $script:preferences)+' · 任务完成';$card.Tag=$Instance.id
    $card.ClientSize=New-Object Drawing.Size(410,140);$card.FormBorderStyle='FixedToolWindow';$card.ShowInTaskbar=$false;$card.TopMost=$true;$card.Font=$panel.Font;$card.StartPosition='Manual'
    $card.Add_FormClosed({param($sender,$e) [void]$script:completionCards.Remove($sender);Update-CompletionCardLayout})
    $description=New-UiLabel $card '此环境有任务已完成。打开对应端查看结果。' 16 14 378 52
    $button=New-UiButton $card '打开对应端' 16 84 210 {
        param($sender,$e)
        if($script:uiBusy){return}
        $owner=$sender.FindForm();$id=[string]$owner.Tag;$target=@($config.instances|Where-Object {$_.id -eq $id})
        if($target.Count -ne 1){return};$owner.Close();Invoke-PanelAction {Open-PanelInstance $target[0]}
    }
    [void](New-UiButton $card '关闭提示' 240 84 152 {param($sender,$e) $sender.FindForm().Close()})
    $script:completionCards.Add($card);Update-CompletionCardLayout;$card.Show()
}
function Set-CompletionNotificationsEnabled([bool]$Enabled) {
    Stop-CompletionWorker;Close-CompletionCards
    $script:completionSettings.enabled=$Enabled
    # Re-enabling starts a fresh baseline; completions while disabled stay silent.
    $script:completionSettings.epoch=[Guid]::NewGuid().ToString('N')
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
            if($event.schema -ne 1 -or $event.epoch -ne $script:completionSettings.epoch -or $instance.Count -ne 1 -or $event.eventId -notmatch '^[a-f0-9]{32}$'){
                Remove-Item -LiteralPath $path -Force;continue
            }
            # Immutable, unique event files avoid racing a producer's atomic replace.
            Remove-Item -LiteralPath $path -Force
            Show-CompletionCard $instance[0]
        }catch{Set-UiMessage '一条独立通知无法读取，已跳过；两端任务不受影响。'}
    }
}
function Dispose-CompletionNotifications {Stop-CompletionWorker;Close-CompletionCards}
