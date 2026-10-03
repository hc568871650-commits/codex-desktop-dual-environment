# Questions stay in memory. Closing a notice never answers or cancels a request.
if(-not ('CodexDual.QuestionBridgeClient' -as [type])){Add-Type -Path "$PSScriptRoot\QuestionBridgeClient.cs" -ReferencedAssemblies System,System.Core,System.Web.Extensions}
. "$PSScriptRoot\QuestionBridgeLaunch.ps1"
$script:questionClient=$null;$script:questionBinding=$null;$script:questionPending=@();$script:questionWindow=$null;$script:questionNotice=$null
$script:questionPreview=$null
$script:questionReturnTarget=$null
$script:questionStatus='尚未连接提问服务';$script:questionPollAt=[DateTime]::MinValue;$script:questionSeen=New-Object 'Collections.Generic.HashSet[string]'
$script:questionNativeForeground=$false
function Read-QuestionBridgeBinding([string]$Directory) {
    $root=Get-FullDirectory $Directory;Assert-NoReparsePoint $root
    if(Test-Path -LiteralPath (Join-Path $root 'binding.json')){
        $api=@($config.instances|Where-Object {$_.role -eq 'api'})
        if($api.Count -ne 1){throw '无法唯一确认 API 环境。'}
        $live=Get-ValidatedApiQuestionBridge -Directory $root -ApiHome $api[0].home -Profile $api[0].profile -InstanceId $api[0].id -IgnoreDisabled
        if(-not $live){throw '本机提问服务的环境或程序校验失败，保留原生作答。'}
        return [pscustomobject]@{directory=$root;pipe=$live.config.pipeName;bridgeInstanceId=$live.config.instanceId;instance=$api[0];proxy=$live.proxy;disabled=$live.disabled}
    }
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
        $previewRequest=[IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'config\question-preview.json'))|ConvertFrom-Json
        $previewRequest|Add-Member NoteProperty taskTitle '预览' -Force
        $script:questionPreview.SetRequestJson(($previewRequest|ConvertTo-Json -Depth 20 -Compress))
        $script:questionPreview.Text='提问界面预览'
        $script:questionPreview.Add_SubmitRequested({param($sender,$e) $sender.SetSubmissionState($false,'这是界面预览，答案未发送。')})
        $script:questionPreview.Add_ReturnRequested({param($sender,$e) $sender.SetSubmissionState($false,'这是界面预览，没有关联真实任务。')})
    }
    $behavior=Get-WindowBehavior $script:preferences
    $script:questionPreview.ApplyAppearance();$script:questionPreview.Present(($behavior.questionMode -ne 'passive'),[bool]$behavior.questionOverlay)
}
function Clear-PendingQuestionState([string]$Reason) {
    $script:questionPending=@();$script:questionStatus=$Reason
    if($script:questionWindow -and -not $script:questionWindow.IsDisposed){$script:questionWindow.InvalidateRequest($Reason)}
    if($script:questionNotice -and -not $script:questionNotice.IsDisposed){$script:questionNotice.Close()}
}
function Close-ResolvedQuestion([string]$Token) {
    # A late reply must never dismiss a newer question the user is editing.
    if($script:questionWindow -and -not $script:questionWindow.IsDisposed -and $script:questionWindow.RequestToken -ceq $Token){
        $script:questionWindow.InvalidateRequest('问题已处理。')
        $script:questionWindow.Hide()
    }
    if($script:questionNotice -and -not $script:questionNotice.IsDisposed -and [string]$script:questionNotice.Tag -ceq $Token){$script:questionNotice.Close()}
}
function Test-QuestionSnapshotConfirmed($Response,[string]$ConnectionId) {
    # Multi-connection discovery can omit a disconnected endpoint entirely.
    # Only that question's responding connection can confirm its disappearance.
    if($Response.PSObject.Properties['confirmedConnections']){return @($Response.confirmedConnections) -ccontains $ConnectionId}
    return [int](Get-ObjectValue $Response 'unavailableConnections' 0) -eq 0
}
function Show-PendingQuestion([string]$Token,[switch]$WithoutFocus) {
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
            if($live.Count -eq 1 -and (Test-TaskIdentifier $live[0].threadId)){
                if([bool](Get-ObjectValue $live[0] 'outcomeUnknown' $false)){$sender.SetSubmissionState($false,'上次提交结果尚未确认，请等待同步，不要重复作答。');return}
                if((Get-ObjectValue $live[0] 'delivery' '') -eq 'exclusive'){
                    $release=@{command='release';connectionId=$live[0].connectionId;requestToken=$live[0].requestToken;requestId=$live[0].requestId;threadId=$live[0].threadId;turnId=$live[0].turnId}|ConvertTo-Json -Compress
                    if($script:questionClient.StartRelease($release,$sender.RequestToken)){$script:questionReturnTarget=$live[0];$sender.SetSubmissionState($true,'正在恢复原生作答入口…')}
                    else{$sender.SetSubmissionState($false,'正在刷新问题，请稍后再返回。')}
                }else{Invoke-PanelAction {Open-CompletionTarget $script:questionBinding.instance $live[0].threadId};$sender.Hide()}
            }
            else{$sender.SetSubmissionState($false,'没有可验证的任务入口，请手动返回 Codex。')}
        })
    }
    $title=Get-CompletionTaskTitle $script:questionBinding.instance $request[0].threadId
    if($title -ne '任务已完成'){$request[0]|Add-Member NoteProperty taskTitle $title -Force}
    $script:questionWindow.SetRequestJson(($request[0]|ConvertTo-Json -Depth 20 -Compress));$script:questionWindow.ApplyAppearance()
    if([bool](Get-ObjectValue $request[0] 'outcomeUnknown' $false)){$script:questionWindow.InvalidateRequest('提交结果尚未确认；正在同步状态，不会自动重发。')}
    if(-not $script:questionWindow.Visible){
        $area=if($script:completionArea){$script:completionArea}else{[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea}
        $script:questionWindow.PlaceNearNotifications($area)
    }
    $behavior=Get-WindowBehavior $script:preferences
    $script:questionWindow.Present((-not $WithoutFocus),[bool]$behavior.questionOverlay)
}
function Show-QuestionNotice($Request) {
    if(-not $script:questionBinding -or -not (Get-ApiFeatureInstance $config $script:questionBinding.instance.id)){return}
    # Recheck at display time as focus may have changed during a snapshot request.
    # Returning ownership to Desktop restores the real native question; merely
    # hiding this card would leave the original question stripped by the proxy.
    if(Test-CompletionForeground $script:questionBinding.instance){
        $script:questionNativeForeground=$true;$script:questionPollAt=[DateTime]::MinValue;return
    }
    if($script:completionReady -and (-not $script:completionSettings.enabled -or (Test-CompletionSnoozed))){return}
    $behavior=Get-WindowBehavior $script:preferences
    $editingOther=$script:questionWindow -and -not $script:questionWindow.IsDisposed -and $script:questionWindow.Visible -and $script:questionWindow.IsRequestValid -and $script:questionWindow.RequestToken -cne $Request.requestToken
    if($behavior.questionMode -ne 'notice' -and -not $editingOther){
        Close-CompletionCards
        Show-PendingQuestion $Request.requestToken -WithoutFocus:($behavior.questionMode -eq 'passive');return
    }
    Close-CompletionCards
    $first=@($Request.questions)[0]
    $card=New-CompactNoticeCard 'API · 需要你回答' '待回答' ([string]$first.question) {param($sender,$e) $owner=$sender.FindForm();Show-PendingQuestion ([string]$owner.Tag);$owner.Close()} '打开问题'
    $script:questionNotice=$card;$card.Tag=$Request.requestToken
    $card|Add-Member NoteProperty QuestionConnectionId ([string]$Request.connectionId)
    if($script:completionReady){$card.SetDisplaySettings(([int]$script:completionSettings.displaySeconds*1000),[bool]$script:completionSettings.fadeEnabled)}
    $card.Add_FormClosed({Update-CompletionCardLayout});Set-UiTheme $card
    $area=[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $card.Location=New-Object Drawing.Point(($area.Right-$card.Width-20),($area.Bottom-$card.Height-20));$card.Show();Update-CompletionCardLayout
}
function Update-PendingQuestions {
    if(-not $script:questionClient){return}
    if(-not $script:questionBinding -or -not (Get-ApiFeatureInstance $config $script:questionBinding.instance.id)){Clear-PendingQuestionState '无法确认 API 实例归属，请在 Codex 中作答。';return}
    if(Test-Path -LiteralPath $script:questionBinding.disabled){Clear-PendingQuestionState '提问服务已停用，请在 Codex 中作答。';return}
    $result=$script:questionClient.Take()
    if($result){
        if($result.Error){Clear-PendingQuestionState '连接中断，请在 Codex 中作答；恢复后会自动刷新。'}
        else{
            try{
                $response=$result.Json|ConvertFrom-Json
                if(-not $response.ok){
                    if($result.Kind -eq 'answer' -and (Get-ObjectValue $response 'error' '') -eq 'steer-rejected'){
                        if($script:questionWindow -and -not $script:questionWindow.IsDisposed){$script:questionWindow.SetSubmissionState($false,'任务未接受回答。请等待问题状态刷新后再试。')}
                        $script:questionPollAt=[DateTime]::MinValue;return
                    }
                    throw 'Request rejected'
                }
                if($result.Kind -eq 'release'){
                    $target=$script:questionReturnTarget;$script:questionReturnTarget=$null
                    if($target -and $target.requestToken -ceq $result.Token){
                        $script:questionPending=@($script:questionPending|Where-Object {$_.requestToken -cne $result.Token})
                        Close-ResolvedQuestion $result.Token
                        Invoke-PanelAction {Open-CompletionTarget $script:questionBinding.instance $target.threadId}
                    }
                    $script:questionPollAt=[DateTime]::MinValue
                }elseif($result.Kind -eq 'answer'){
                    $script:questionPending=@($script:questionPending|Where-Object {$_.requestToken -cne $result.Token})
                    Close-ResolvedQuestion $result.Token
                    $script:questionPollAt=[DateTime]::MinValue
                }else{
                    $oldCount=@($script:questionPending).Count;$script:questionPending=@($response.pending)
                    foreach($item in $script:questionPending){if($item.requestToken -notmatch '^[a-f0-9]{32}$' -or -not $item.connectionId -or -not @($item.questions).Count){throw 'Invalid request'}}
                    $takeover=[bool](Get-ObjectValue $response 'takeoverActive' $false)
                    $script:questionStatus=if($script:questionPending.Count){'有 '+$script:questionPending.Count+' 项等待处理'}elseif($takeover){'已接管 API 提问，暂无待处理问题'}else{'已连接，原生问题入口仍保留'}
                    # Hide the old external surface only after a verified snapshot
                    # confirms native ownership and no unresolved external submission.
                    if($script:questionNativeForeground -and -not $takeover -and $script:questionPending.Count -eq 0 -and [int](Get-ObjectValue $response 'unavailableConnections' 0) -eq 0){
                        $script:questionStatus='API 当前在前台，使用 Codex 原生提问'
                    }
                    if([int](Get-ObjectValue $response 'unavailableConnections' 0) -gt 0){$script:questionStatus+='；部分连接正在恢复'}
                    if($script:questionWindow -and -not $script:questionWindow.IsDisposed){
                        $live=@($script:questionPending|Where-Object {$_.requestToken -ceq $script:questionWindow.RequestToken})
                        if($live.Count -eq 0){
                            $confirmed=Test-QuestionSnapshotConfirmed $response $script:questionWindow.RequestConnectionId
                            $missingReason=if(-not $confirmed){'该问题连接暂不可确认，正在恢复；草稿已保留。'}else{'问题已在别处处理或已结束。'}
                            $script:questionWindow.InvalidateRequest($missingReason)
                            if($confirmed){Close-ResolvedQuestion $script:questionWindow.RequestToken}
                        }
                        elseif([bool](Get-ObjectValue $live[0] 'outcomeUnknown' $false)){$script:questionWindow.InvalidateRequest('提交结果尚未确认；正在同步状态，不会自动重发。')}
                        elseif(-not $script:questionWindow.IsRequestValid){
                            # A transient connection failure disables submission, but a verified
                            # snapshot of the SAME token restores the draft and answer controls.
                            $script:questionWindow.SetRequestJson(($live[0]|ConvertTo-Json -Depth 20 -Compress))
                        }
                    }
                    foreach($item in $script:questionPending){if($script:questionSeen.Add([string]$item.requestToken)){Show-QuestionNotice $item}}
                    if($script:questionSeen.Count -gt 256){$script:questionSeen.Clear();foreach($item in $script:questionPending){[void]$script:questionSeen.Add([string]$item.requestToken)}}
                    if($oldCount -eq 0 -and $script:questionPending.Count -gt 0 -and (Get-Variable notificationListMode -Scope Script -ErrorAction SilentlyContinue)){$script:notificationListMode='pending';$script:notificationHistoryPage=0}
                    if($script:questionNotice -and -not $script:questionNotice.IsDisposed -and -not @($script:questionPending|Where-Object {$_.requestToken -ceq $script:questionNotice.Tag}).Count -and (Test-QuestionSnapshotConfirmed $response $script:questionNotice.QuestionConnectionId)){$script:questionNotice.Close()}
                }
            }catch{Clear-PendingQuestionState '无法确认问题状态，请在 Codex 中检查；不会自动重发答案。'}
        }
    }
    if(-not $script:questionClient.Busy -and [DateTime]::UtcNow -ge $script:questionPollAt){
        $script:questionPollAt=[DateTime]::UtcNow.AddMilliseconds(900)
        # Foreground API uses its native questions. Background snooze still only
        # hides reminders, retaining external ownership and pending-page access.
        $script:questionNativeForeground=Test-CompletionForeground $script:questionBinding.instance
        [void]$script:questionClient.StartSnapshot((-not $script:questionNativeForeground))
    }
}
function Dispose-PendingQuestions {
    if($script:questionClient){$script:questionClient.Dispose();$script:questionClient=$null}
    if($script:questionWindow -and -not $script:questionWindow.IsDisposed){$script:questionWindow.Dispose()};$script:questionWindow=$null
    if($script:questionNotice -and -not $script:questionNotice.IsDisposed){$script:questionNotice.Dispose()};$script:questionNotice=$null
    if($script:questionPreview -and -not $script:questionPreview.IsDisposed){$script:questionPreview.Dispose()};$script:questionPreview=$null
    $script:questionPending=@();$script:questionBinding=$null;$script:questionReturnTarget=$null;$script:questionSeen.Clear()
    $script:questionNativeForeground=$false
}
