# Questions stay in memory. Closing a notice never answers or cancels a request.
if(-not ('CodexDual.QuestionBridgeClient' -as [type])){Add-Type -Path "$PSScriptRoot\QuestionBridgeClient.cs" -ReferencedAssemblies System,System.Core,System.Web.Extensions}
$script:questionClient=$null;$script:questionBinding=$null;$script:questionPending=@();$script:questionWindow=$null;$script:questionNotice=$null
$script:questionPreview=$null
$script:questionStatus='尚未连接提问服务';$script:questionPollAt=[DateTime]::MinValue;$script:questionSeen=New-Object 'Collections.Generic.HashSet[string]'
function Read-QuestionBridgeBinding([string]$Directory) {
    $root=Get-FullDirectory $Directory;Assert-NoReparsePoint $root
    $manifestPath=Join-Path $root 'trial.json';$bridgePath=Join-Path $root 'bridge.config.json'
    Assert-NoReparsePoint $manifestPath;Assert-NoReparsePoint $bridgePath
    $m=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    $b=Get-Content -LiteralPath $bridgePath -Raw -Encoding UTF8|ConvertFrom-Json
    $api=@($config.instances|Where-Object {$_.role -eq 'api'})
    if($api.Count -ne 1 -or $m.schema -ne 1 -or $m.kind -ne 'isolated-api-bridge-trial' -or $m.id -notmatch '^[a-f0-9]{32}$' -or -not (Test-SamePath $m.root $root)){throw '请选择有效的独立提问服务目录。'}
    if(-not (Test-SamePath $m.apiHome $api[0].home) -or -not (Test-SamePath $m.profile $api[0].profile) -or -not (Test-SamePath $m.apiHome (Join-Path $root 'CodexHome')) -or -not (Test-SamePath $m.profile (Join-Path $root 'DesktopProfile'))){throw '提问服务不属于此控制器登记的 API 环境，未连接。'}
    if($b.instanceId -ne ('api-trial-'+$m.id) -or $b.pipeName -ne ('codex-api-question-trial-'+$m.id) -or -not (Test-SamePath $b.apiHome $m.apiHome) -or -not (Test-SamePath $b.realCli $m.realCli)){throw '提问服务的实例绑定已变化，未连接。'}
    $proxy=Join-Path $root 'BridgeProxy.exe';Assert-NoReparsePoint $proxy
    if((Get-FileHash -LiteralPath $proxy -Algorithm SHA256).Hash -ne $m.proxyHash){throw '提问服务程序已变化，请重新验证后连接。'}
    return [pscustomobject]@{directory=$root;pipe=$b.pipeName;bridgeInstanceId=$b.instanceId;instance=$api[0];proxy=$proxy;disabled=(Join-Path $root 'DISABLED')}
}
function Connect-QuestionBridge([string]$Directory,[switch]$Persist) {
    $binding=Read-QuestionBridgeBinding $Directory
    if($Persist){$path=Join-Path $config.stateDirectory 'question-bridge.local.json';Assert-NoReparsePoint $path;Write-AtomicText $path (@{schema=1;directory=$binding.directory;instanceId=$binding.instance.id}|ConvertTo-Json)}
    Dispose-PendingQuestions
    $script:questionBinding=$binding
    $script:questionClient=New-Object CodexDual.QuestionBridgeClient($binding.pipe,$binding.proxy,$binding.bridgeInstanceId,$binding.disabled)
    $script:questionStatus='正在连接提问服务…';$script:questionPollAt=[DateTime]::MinValue
}
function Initialize-PendingQuestions {
    $path=Join-Path $config.stateDirectory 'question-bridge.local.json';Assert-NoReparsePoint $path
    if(Test-Path -LiteralPath $path){
        try{$saved=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json;if($saved.schema -ne 1){throw 'Unsupported binding'};Connect-QuestionBridge $saved.directory;if($script:questionBinding.instance.id -ne $saved.instanceId){Dispose-PendingQuestions;throw 'Instance changed'}}
        catch{$script:questionStatus='提问连接不可用，请重新连接；可在 Codex 中作答。'}
    }
}
function Select-QuestionBridge {
    $dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='选择此 API 环境已经验证的提问服务目录'
    try{if($dialog.ShowDialog() -eq 'OK'){Connect-QuestionBridge $dialog.SelectedPath -Persist;Update-NotificationView -Force}}catch{Show-Error $_}finally{$dialog.Dispose()}
}
function Get-PendingQuestionEntries {return @($script:questionPending)}
function Show-QuestionPreview {
    if(-not $script:questionPreview -or $script:questionPreview.IsDisposed){
        $script:questionPreview=New-Object CodexDual.QuestionWindow
        $script:questionPreview.SetRequestJson([IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'config\question-preview.json')))
        $script:questionPreview.Text='提问界面预览';$script:questionPreview.Controls.Find('QuestionContext',$true)[0].Text='界面预览 · 不会发送到任何任务'
        $script:questionPreview.Add_SubmitRequested({param($sender,$e) $sender.SetSubmissionState($false,'这是界面预览，答案未发送。')})
        $script:questionPreview.Add_ReturnRequested({param($sender,$e) $sender.SetSubmissionState($false,'这是界面预览，没有关联真实任务。')})
    }
    $script:questionPreview.ApplyAppearance();$script:questionPreview.Show();$script:questionPreview.Activate()
}
function Clear-PendingQuestionState([string]$Reason) {
    $script:questionPending=@();$script:questionStatus=$Reason
    if($script:questionWindow -and -not $script:questionWindow.IsDisposed){$script:questionWindow.InvalidateRequest($Reason)}
    if($script:questionNotice -and -not $script:questionNotice.IsDisposed){$script:questionNotice.Close()}
}
function Show-PendingQuestion([string]$Token) {
    $request=@($script:questionPending|Where-Object {$_.requestToken -ceq $Token})
    if($request.Count -ne 1){Set-UiMessage '该问题已失效，请查看最新待处理列表。';return}
    if(-not $script:questionWindow -or $script:questionWindow.IsDisposed){
        $script:questionWindow=New-Object CodexDual.QuestionWindow
        $script:questionWindow.Add_SubmitRequested({param($sender,$e)
            $live=@($script:questionPending|Where-Object {$_.requestToken -ceq $sender.RequestToken})
            if($live.Count -ne 1 -or -not $script:questionClient){$sender.InvalidateRequest('该问题已失效，请回到待处理列表。');return}
            if($script:questionClient.StartAnswer($sender.AnswerJson,$sender.RequestToken)){$sender.SetSubmissionState($true,'正在提交…')}else{$sender.SetSubmissionState($false,'正在刷新问题，请稍后再提交。')}
        })
        $script:questionWindow.Add_ReturnRequested({param($sender,$e)
            if($script:openBusy -or $script:uiBusy){$sender.SetSubmissionState($false,'正在打开任务，请稍后。');return}
            $live=@($script:questionPending|Where-Object {$_.requestToken -ceq $sender.RequestToken})
            if($live.Count -eq 1 -and (Test-TaskIdentifier $live[0].threadId)){Invoke-PanelAction {Open-CompletionTarget $script:questionBinding.instance $live[0].threadId};$sender.Hide()}
            else{$sender.SetSubmissionState($false,'没有可验证的任务入口，请手动返回 Codex。')}
        })
    }
    $title=Get-CompletionTaskTitle $script:questionBinding.instance $request[0].threadId
    if($title -ne '任务已完成'){$request[0]|Add-Member NoteProperty taskTitle $title -Force}
    $script:questionWindow.SetRequestJson(($request[0]|ConvertTo-Json -Depth 20 -Compress));$script:questionWindow.ApplyAppearance()
    if(-not $script:questionWindow.Visible){
        $area=if($script:completionArea){$script:completionArea}else{[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea}
        $script:questionWindow.PlaceNearNotifications($area);$script:questionWindow.Show()
    };$script:questionWindow.Activate()
}
function Show-QuestionNotice($Request) {
    if($script:completionReady -and (Test-CompletionSnoozed)){return}
    if($script:questionNotice -and -not $script:questionNotice.IsDisposed){$script:questionNotice.Close()}
    $card=New-Object CodexDual.CompletionCard;$script:questionNotice=$card
    $card.Text='API · 需要你回答';$card.ClientSize=New-Object Drawing.Size(420,192);$card.ShowInTaskbar=$false;$card.TopMost=$true;$card.StartPosition='Manual';$card.Font=$panel.Font;$card.Tag=$Request.requestToken
    if($script:completionReady){$card.SetDisplaySettings(([int]$script:completionSettings.displaySeconds*1000),[bool]$script:completionSettings.fadeEnabled)}
    $label=New-UiLabel $card 'API · 等待你的回答' 20 16 330 24;$label.Name='Muted'
    $first=@($Request.questions)[0];$title=New-UiLabel $card ([string]$first.question) 20 49 375 54;$title.AutoEllipsis=$true
    $title.Font=New-Object Drawing.Font($panel.Font.FontFamily,11,[Drawing.FontStyle]::Bold)
    [void](New-UiLabel $card '提示收起后，仍可在通知页的待处理中回答。' 20 110 375 24)
    $open=New-UiButton $card '查看并回答' 20 148 235 {param($sender,$e) $owner=$sender.FindForm();Show-PendingQuestion ([string]$owner.Tag);$owner.Close()};$open.Primary=$true
    [void](New-UiButton $card '稍后处理' 267 148 130 {param($sender,$e) $sender.FindForm().Close()})
    $card.Add_FormClosed({Update-CompletionCardLayout});Set-UiTheme $card
    $area=[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $card.Location=New-Object Drawing.Point(($area.Right-$card.Width-20),($area.Bottom-$card.Height-20));$card.Show();Update-CompletionCardLayout
}
function Update-PendingQuestions {
    if(-not $script:questionClient){return}
    if(Test-Path -LiteralPath $script:questionBinding.disabled){Clear-PendingQuestionState '提问服务已停用，请在 Codex 中作答。';return}
    $result=$script:questionClient.Take()
    if($result){
        if($result.Error){Clear-PendingQuestionState '连接中断，请在 Codex 中作答；恢复后会自动刷新。'}
        else{
            try{
                $response=$result.Json|ConvertFrom-Json
                if(-not $response.ok){throw 'Request rejected'}
                if($result.Kind -eq 'answer'){
                    $script:questionPending=@($script:questionPending|Where-Object {$_.requestToken -cne $result.Token})
                    if($script:questionWindow -and -not $script:questionWindow.IsDisposed -and $script:questionWindow.RequestToken -ceq $result.Token){$script:questionWindow.InvalidateRequest('回答已发送，请在原任务查看后续结果。')}
                    $script:questionPollAt=[DateTime]::MinValue
                }else{
                    $oldCount=@($script:questionPending).Count;$script:questionPending=@($response.pending)
                    foreach($item in $script:questionPending){if($item.requestToken -notmatch '^[a-f0-9]{32}$' -or -not $item.connectionId -or -not @($item.questions).Count){throw 'Invalid request'}}
                    $script:questionStatus=if($script:questionPending.Count){'有 '+$script:questionPending.Count+' 项等待处理'}else{'已连接，暂无待处理问题'}
                    if($script:questionWindow -and -not $script:questionWindow.IsDisposed){
                        $live=@($script:questionPending|Where-Object {$_.requestToken -ceq $script:questionWindow.RequestToken})
                        if($live.Count -eq 0){$script:questionWindow.InvalidateRequest('问题已在别处处理或已结束。')}
                    }
                    foreach($item in $script:questionPending){if($script:questionSeen.Add([string]$item.requestToken)){Show-QuestionNotice $item}}
                    if($script:questionSeen.Count -gt 256){$script:questionSeen.Clear();foreach($item in $script:questionPending){[void]$script:questionSeen.Add([string]$item.requestToken)}}
                    if($oldCount -eq 0 -and $script:questionPending.Count -gt 0 -and (Get-Variable notificationListMode -Scope Script -ErrorAction SilentlyContinue)){$script:notificationListMode='pending';$script:notificationHistoryPage=0}
                    if($script:questionNotice -and -not $script:questionNotice.IsDisposed -and -not @($script:questionPending|Where-Object {$_.requestToken -ceq $script:questionNotice.Tag}).Count){$script:questionNotice.Close()}
                }
            }catch{Clear-PendingQuestionState '无法确认问题状态，请在 Codex 中检查；不会自动重发答案。'}
        }
    }
    if(-not $script:questionClient.Busy -and [DateTime]::UtcNow -ge $script:questionPollAt){$script:questionPollAt=[DateTime]::UtcNow.AddMilliseconds(900);[void]$script:questionClient.StartSnapshot()}
}
function Dispose-PendingQuestions {
    if($script:questionClient){$script:questionClient.Dispose();$script:questionClient=$null}
    if($script:questionWindow -and -not $script:questionWindow.IsDisposed){$script:questionWindow.Dispose()};$script:questionWindow=$null
    if($script:questionNotice -and -not $script:questionNotice.IsDisposed){$script:questionNotice.Dispose()};$script:questionNotice=$null
    if($script:questionPreview -and -not $script:questionPreview.IsDisposed){$script:questionPreview.Dispose()};$script:questionPreview=$null
    $script:questionPending=@();$script:questionBinding=$null;$script:questionSeen.Clear()
}
