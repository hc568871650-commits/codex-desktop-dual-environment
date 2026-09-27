$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\..\src\Panel.ps1"
. "$PSScriptRoot\..\src\CompletionNotifications.ps1"

$script:passed=0
function Check($Value,[string]$Message){if(-not $Value){throw ('FAIL: '+$Message)};$script:passed++;Write-Output ('PASS: '+$Message)}
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('notification-toggle-'+[Guid]::NewGuid().ToString('N'))
$config=[pscustomobject]@{stateDirectory=$root;instances=@([pscustomobject]@{id=('a'*32);role='official'},[pscustomobject]@{id=('b'*32);role='api'})}
$ConfigPath=Join-Path $root 'fixture.local.json';$SmokeTest=$true
$script:preferences=@{names=@{}};$script:uiBusy=$false;$script:openBusy=$false;$script:opened=@()
$panel=New-Object Windows.Forms.Form;$panel.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
$script:feedbackCount=0
function Set-UiMessage([string]$Message){$script:lastFeedback=$Message;$script:feedbackCount++}
function Open-PanelInstance($Instance){$script:opened+=$Instance.id}
function Start-PanelOpen([string[]]$Roles,[string]$ThreadId,[switch]$FromNotification){$script:opened+=$ThreadId}

# This test replaces the launch boundary with an inert, controller-owned sleep process.
# NotificationWorker.ps1 and user instances are never launched.
$script:started=New-Object 'Collections.Generic.List[Diagnostics.Process]'
function Start-CompletionWorker {
    if(-not $script:completionSettings.enabled -or $script:retiringCompletionWorkers.Count -or ($script:completionWorker -and -not $script:completionWorker.HasExited)){return}
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $info.Arguments='-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $script:completionWorker=[Diagnostics.Process]::Start($info)
    $script:completionRunId=[Guid]::NewGuid().ToString('N')
    $script:started.Add($script:completionWorker)
}

try{
    Initialize-CompletionNotifications
    [void][IO.Directory]::CreateDirectory($script:completionRoot)
    Start-CompletionWorker
    $first=$script:completionWorker
    $script:completionSettings|Add-Member NoteProperty futureField 'retain-me' -Force
    $beforeSettings=$script:completionSettings;$beforeEpoch=$beforeSettings.epoch
    $savedWrite=${function:Save-CompletionSettings}
    Set-Item function:Save-CompletionSettings -Value {throw 'fixture settings write failure'}
    $writeFailed=$false
    try{Set-CompletionNotificationsEnabled $false}catch{$writeFailed=$true}
    finally{Set-Item function:Save-CompletionSettings -Value $savedWrite}
    Check ($writeFailed -and [object]::ReferenceEquals($beforeSettings,$script:completionSettings) -and $script:completionSettings.enabled -and $script:completionSettings.epoch -eq $beforeEpoch -and [object]::ReferenceEquals($first,$script:completionWorker) -and -not $first.HasExited -and $script:retiringCompletionWorkers.Count -eq 0) 'Failed settings save leaves old worker, memory state, and epoch untouched'
    $script:toggleFinished=$false;$script:toggleElapsed=0
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=10
    $timer.Add_Tick({
        $timer.Stop()
        $watch=[Diagnostics.Stopwatch]::StartNew()
        Set-CompletionNotificationsEnabled $false
        Set-CompletionNotificationsEnabled $true
        Set-CompletionNotificationsEnabled $false
        Set-CompletionNotificationsEnabled $true
        $watch.Stop();$script:toggleElapsed=$watch.ElapsedMilliseconds
        $script:toggleFinished=$true
    })
    $timer.Start()
    $deadline=[DateTime]::UtcNow.AddSeconds(3)
    while(-not $script:toggleFinished -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 5}
    Check ($script:toggleFinished -and $script:toggleElapsed -lt 800) 'Rapid toggles complete inside a live WinForms message loop without blocking for worker exit'
    Check ($script:started.Count -eq 1 -and $script:completionRestartPending -and $script:retiringCompletionWorkers.Count -eq 1) 'Rapid toggles retain one old worker and queue one restart'
    Check ((Read-CompletionSettings $config).futureField -eq 'retain-me') 'Successful toggles preserve unknown settings fields'
    Check ((Get-CompletionStatusText) -eq '正在切换') 'Pending restart exposes transition state'
    Set-CompletionNotificationsEnabled $false
    Check (-not $script:completionRestartPending -and $script:started.Count -eq 1) 'Disabling while old worker retires cancels the queued restart'
    Set-CompletionNotificationsEnabled $true
    $first.Kill();[void]$first.WaitForExit(2000)
    Update-CompletionNotifications
    Check ($script:started.Count -eq 2 -and $script:retiringCompletionWorkers.Count -eq 0 -and -not $script:completionRestartPending) 'Exited worker is disposed before exactly one replacement starts'

    $secondPid=$script:completionWorker.Id
    Set-CompletionNotificationsEnabled $false
    Check ((Get-CompletionStatusText) -eq '已关闭') 'Disable cancels pending restart immediately'
    $script:retiringCompletionWorkers[0].deadline=[DateTime]::UtcNow.AddMilliseconds(-1)
    $deadline=[DateTime]::UtcNow.AddSeconds(2)
    while($script:retiringCompletionWorkers.Count -and [DateTime]::UtcNow -lt $deadline){Update-CompletionNotifications;[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    Check ($script:retiringCompletionWorkers.Count -eq 0 -and $null -eq $script:completionWorker -and -not (Get-Process -Id $secondPid -ErrorAction SilentlyContinue)) 'Expired retirement kills only the owned fixture worker without restarting'
    Check ($script:started.Count -eq 2) 'Disabling a queued restart creates no extra process'
    Set-CompletionSnooze 15
    $script:completionSettings.enabled=$true
    Check ((Get-CompletionStatusText) -like '暂停至??:??') 'Status reports the persisted local snooze expiry'
    Set-CompletionSnooze 0
    Start-CompletionWorker
    $script:completionWorker.Kill();[void]$script:completionWorker.WaitForExit(2000)
    Check ((Get-CompletionStatusText) -eq '监听已停止') 'Unexpected worker exit is visible without automatic restart'
    Update-CompletionNotifications
    Check ($script:started.Count -eq 3) 'Unexpected exit is not restarted on the periodic update'
    Set-CompletionNotificationsEnabled $false

    $historyCount=$script:completionHistory.Count
    Show-CompletionCard $config.instances[1]
    $real=$script:completionCards[0]
    Show-CompletionPreview
    Check ($script:completionCards.Count -eq 2 -and -not $real.IsDisposed -and $script:completionCards[1].Tag -eq 'preview') 'Preview coexists with a real API notification'
    $preview=$script:completionCards[1]
    Check ((@($preview.Controls|Where-Object {$_.Name -eq 'Muted'}).Count -eq 2) -and @($preview.Controls|Where-Object {$_.Text -like '*预览*'}).Count -ge 1) 'Preview labels expose theme role and visible preview wording'
    Check (@($preview.Controls|Where-Object {$_.Text -eq '关闭提示' -or $_.Text -eq '暂停提醒…'}).Count -eq 0 -and @($preview.Controls|Where-Object {$_.Text -eq '关闭预览'})[0].Width -eq 384) 'Preview has one wide primary action and no redundant secondary actions'
    @($preview.Controls|Where-Object {$_.Text -eq '关闭预览'})[0].PerformClick()
    Check ($preview.IsDisposed -and $script:completionCards.Count -eq 1 -and $script:completionHistory.Count -eq $historyCount -and $script:opened.Count -eq 0 -and $script:started.Count -eq 3) 'Preview closes without opening instances, writing history, or launching a worker'

    Set-CompletionNotificationsEnabled $true
    $thirdPid=$script:completionWorker.Id
    Dispose-CompletionNotifications
    Check ($script:retiringCompletionWorkers.Count -eq 0 -and $null -eq $script:completionWorker -and -not (Get-Process -Id $thirdPid -ErrorAction SilentlyContinue)) 'Dispose fully cleans the remaining owned worker'

    Initialize-CompletionNotifications
    Start-CompletionWorker
    $last=$script:completionWorker
    Set-CompletionNotificationsEnabled $false
    Set-CompletionNotificationsEnabled $true
    $last.Kill();[void]$last.WaitForExit(2000)
    $savedStart=${function:Start-CompletionWorker}
    $script:startAttempts=0;$script:feedbackCount=0;$SmokeTest=$false
    Set-Item function:Start-CompletionWorker -Value {$script:startAttempts++;throw 'fixture launch failure'}
    try{
        Update-CompletionNotifications
        Check ($script:startAttempts -eq 1 -and $script:feedbackCount -eq 1 -and -not $script:completionRestartPending -and (Get-CompletionStatusText) -eq '监听已停止') 'Queued launch failure stays inside timer update and exposes stopped status once'
        Update-CompletionNotifications;Update-CompletionNotifications
        Check ($script:startAttempts -eq 1 -and $script:feedbackCount -eq 1) 'Later ticks neither retry failed launch nor repeat its message'
    }finally{Set-Item function:Start-CompletionWorker -Value $savedStart;$SmokeTest=$true}
}finally{
    if($timer){$timer.Dispose()}
    Dispose-CompletionNotifications
    foreach($worker in $script:started){try{if(-not $worker.HasExited){$worker.Kill()}}catch{};try{$worker.Dispose()}catch{}}
    $panel.Dispose()
}
Write-Output "PASSED: $script:passed notification toggle checks. Output: $root"
