$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
Add-Type -Path "$PSScriptRoot\HostAutomation.cs"
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('host-'+[Guid]::NewGuid().ToString('N')+' space 中文')
$install=Join-Path $root 'Tool';$data=Join-Path $root 'Data';$official=Join-Path $root 'Official'
$fake=ConvertTo-SecureString 'fixture-host-no-real-key' -AsPlainText -Force
[void][IO.Directory]::CreateDirectory($root)
$fixtureExe=Join-Path $root 'Fixture.exe'
Add-Type -Path "$PSScriptRoot\Fixture.cs" -ReferencedAssemblies System.Windows.Forms,System.Drawing -OutputAssembly $fixtureExe -OutputType WindowsApplication
& "$PSScriptRoot\..\scripts\Install.ps1" -InstallDirectory $install -DataDirectory $data -OfficialHome $official -OfficialProfile (Join-Path $root 'OfficialProfile') -Executable $fixtureExe -BaseUrl 'https://example.com/v1' -Model 'example-model' -ApiKey $fake -NoShortcuts
$exe=Join-Path $install 'CodexDualController.exe';$configPath=Join-Path $install 'instances.local.json';$config=Read-ControllerConfig $configPath
# Test only the disposable installed script under a unique mutex. Keep the live
# controller untouched; Test-Controller separately exercises singleton enforcement.
$installedController=Join-Path $install 'src\Controller.ps1'
$installedText=[IO.File]::ReadAllText($installedController)
$productionMutex="'Local\CodexDual.Controller.'"
if(-not $installedText.Contains($productionMutex)){throw 'Controller mutex test seam not found'}
$installedText=$installedText.Replace($productionMutex,("'Local\CodexDual.HostTest."+[Guid]::NewGuid().ToString('N')+".'"))
[IO.File]::WriteAllText($installedController,$installedText,(New-Object Text.UTF8Encoding($true)))
$panelPattern='*'+(Get-Content (Join-Path $install 'version.json') -Raw|ConvertFrom-Json).version+'*'
$completionLog=Join-Path $config.instances[1].home 'sessions\2001\01\01\rollout-notification.jsonl'
[void][IO.Directory]::CreateDirectory((Split-Path $completionLog -Parent))
$meta=@{type='session_meta';payload=@{id=[Guid]::NewGuid().ToString();source='vscode';originator='Codex Desktop'}}|ConvertTo-Json -Depth 5 -Compress
[IO.File]::WriteAllText($completionLog,$meta+"`n",(New-Object Text.UTF8Encoding($false)))
$workerStatusPath=Join-Path $install 'state\notifications\worker-status.local.json'
$original=@(Get-ProcessSnapshot|Where-Object {$_.Name -in @('ChatGPT.exe','Codex.exe')})
$script:passed=0
function Check($Value,$Message){if(-not $Value){throw "FAIL: $Message"};$script:passed++;Write-Output "PASS: $Message"}
function Wait-Condition([scriptblock]$Condition,[string]$Message){for($i=0;$i -lt 60;$i++){if(& $Condition){return};Start-Sleep -Milliseconds 200};throw "Timeout: $Message"}
function Find-Window([string]$Title){return ,@([CodexDual.Native]::Windows($process.Id)|Where-Object {$_.Visible -and $_.Title -like $Title})}
function Get-Element([long]$Handle){return $Handle}
function Click-Button([long]$Element,[string]$Name){
    $buttons=@([CodexDualTests.HostAutomation]::Children($Element,'BUTTON',$Name))
    if(-not $buttons.Count){throw "Button not found in test window: $Name"}
    [CodexDualTests.HostAutomation]::Click($buttons[0])
}
function Start-TestHost([string]$Arguments){
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$exe;$psi.Arguments=$Arguments;$psi.UseShellExecute=$false;$psi.WorkingDirectory=$install
    return [Diagnostics.Process]::Start($psi)
}
$process=$null
$fixtureProcesses=@()
try{
    $process=Start-TestHost ('--background --config "'+$configPath+'"')
    $hashAlgorithm=[Security.Cryptography.SHA256]::Create()
    try{$configHash=[BitConverter]::ToString($hashAlgorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($configPath.ToLowerInvariant()))).Replace('-','')}finally{$hashAlgorithm.Dispose()}
    $eventName='Local\CodexDual.Panel.'+$sid+'.'+$configHash
    Wait-Condition {try{$event=[Threading.EventWaitHandle]::OpenExisting($eventName);$event.Dispose();return $true}catch{return $false}} 'background host initialized'
    Wait-Condition {(Get-Content (Join-Path $install 'state\controller-startup.log') -Raw).Contains('ready-tray')} 'background readiness logged'
    Check (@([CodexDual.Native]::Windows($process.Id)|Where-Object {$_.Visible}).Count -eq 0) 'Compiled EXE background mode has no visible panel'
    $second=Start-TestHost ('--config "'+$configPath+'"')
    try{Check ($second.WaitForExit(12000) -and $second.ExitCode -eq 0) 'Second EXE launch forwards to existing controller'}finally{$second.Dispose()}
    Wait-Condition {(Find-Window $panelPattern).Count -eq 1} 'main panel visible'
    $main=(Find-Window $panelPattern)[0];$element=Get-Element $main.Handle
    Check (@([CodexDualTests.HostAutomation]::Children($element,'BUTTON','×')).Count -eq 1) 'Custom title bar exposes close-to-tray control'
    Click-Button $element '偏好设置'
    Wait-Condition {@([CodexDualTests.HostAutomation]::Children($element,'BUTTON','浅色')).Count -eq 1} 'appearance page visible'
    Click-Button $element '浅色'
    Wait-Condition {(Read-ControllerPreferences $config).appearance.mode -eq 'light'} 'light mode saved by real button'
    Click-Button $element '蓝色'
    Wait-Condition {(Read-ControllerPreferences $config).appearance.accent -eq 'blue'} 'accent saved by real button'
    Check $true 'Appearance buttons persist mode and accent in the compiled app'
    Click-Button $element '通知'
    Wait-Condition {@([CodexDualTests.HostAutomation]::Children($element,'BUTTON','预览通知')).Count -eq 1} 'dedicated notifications page'
    Check (@([CodexDualTests.HostAutomation]::Children($element,'BUTTON','浅色')).Count -eq 0) 'Notification navigation does not land on preferences'
    Click-Button $element '预览通知'
    Wait-Condition {[CodexDualTests.HostAutomation]::FindDialog($process.Id,'API 环境 · 通知预览') -ne 0} 'notification preview visible'
    $previewHandle=[CodexDualTests.HostAutomation]::FindDialog($process.Id,'API 环境 · 通知预览')
    Click-Button $previewHandle '关闭预览'
    Wait-Condition {[CodexDualTests.HostAutomation]::FindDialog($process.Id,'API 环境 · 通知预览') -eq 0} 'preview dismissed'
    Check $true 'Preview opens and closes without launching either fixture environment'
    Click-Button $element '显示设置'
    Wait-Condition {[CodexDualTests.HostAutomation]::FindDialog($process.Id,'通知显示设置') -ne 0} 'display settings visible'
    $displayDialog=[CodexDualTests.HostAutomation]::FindDialog($process.Id,'通知显示设置')
    $duration=@([CodexDualTests.HostAutomation]::Children($displayDialog,'COMBOBOX',$null))
    Check ($duration.Count -eq 1) 'Compiled host exposes notification duration control'
    [CodexDualTests.HostAutomation]::SelectComboIndex($duration[0],1)
    Click-Button $displayDialog '保存'
    Wait-Condition {(Get-Content (Join-Path $install 'state\notifications\settings.local.json') -Raw|ConvertFrom-Json).displaySeconds -eq 5} 'compiled-host duration saved'
    Check ([CodexDualTests.HostAutomation]::FindDialog($process.Id,'通知显示设置') -eq 0 -and [CodexDualTests.HostAutomation]::FindDialog($process.Id,'Microsoft .NET Framework') -eq 0) 'Display settings save resolves controller functions without closure errors'
    Click-Button $element '任务完成时显示提醒'
    Wait-Condition {-not (Get-Content (Join-Path $install 'state\notifications\settings.local.json') -Raw|ConvertFrom-Json).enabled} 'notification disabled from dedicated page'
    Check ([CodexDualTests.HostAutomation]::Responds($main.Handle)) 'Panel remains responsive while stopping notification worker'
    Click-Button $element '任务完成时显示提醒'
    Wait-Condition {(Get-Content (Join-Path $install 'state\notifications\settings.local.json') -Raw|ConvertFrom-Json).enabled} 'notification enabled from dedicated page'
    Wait-Condition {(Test-Path $workerStatusPath) -and (Get-Content $workerStatusPath -Raw|ConvertFrom-Json).state -eq 'running'} 'worker restarted after notification toggle'
    Click-Button $element '偏好设置'
    Wait-Condition {@([CodexDualTests.HostAutomation]::Children($element,'BUTTON','深色')).Count -eq 1} 'preferences visible again'
    Click-Button $element '深色'
    Wait-Condition {(Read-ControllerPreferences $config).appearance.mode -eq 'dark'} 'dark mode restored'
    Click-Button $element '中性'
    Wait-Condition {(Read-ControllerPreferences $config).appearance.accent -eq 'neutral'} 'neutral accent restored'
    Click-Button $element '概览'
    Wait-Condition {@([CodexDualTests.HostAutomation]::Children($element,'BUTTON','同时打开两边')).Count -eq 1} 'overview restored'
    Click-Button $element '−'
    Wait-Condition {[CodexDualTests.HostAutomation]::IsMinimized($main.Handle)} 'custom minimize control'
    $restoreEvent=[Threading.EventWaitHandle]::OpenExisting($eventName)
    try{[void]$restoreEvent.Set()}finally{$restoreEvent.Dispose()}
    Wait-Condition {-not [CodexDualTests.HostAutomation]::IsMinimized($main.Handle)} 'minimized panel restored'
    Check $true 'Custom minimize and panel restore preserve the window'
    # Actual 0.4 controls against two disposable GUI instances, including window selection.
    $officialFixture=$config.instances[0]
    Write-AtomicText (Join-Path $officialFixture.profile 'stubborn.fixture') ''
    Click-Button $element '同时打开两边'
    # A cold-start snapshot may see the primary window before Shown creates the
    # secondary window. Handle any selectors, then assert both actual outcomes.
    Wait-Condition {
        $selectors=Find-Window '选择要显示的窗口'
        if($selectors.Count){Click-Button $selectors[0].Handle '显示选中窗口';return $false}
        $description=[CodexDualTests.HostAutomation]::Describe($process.Id)
        # Windows may decline foreground focus; Running is a supported result.
        return ($description -match '官方环境：(已显示窗口|已运行；请点击其任务栏窗口)' -and $description -match 'API 环境：(已显示窗口|已运行；请点击其任务栏窗口)')
    } 'both cold-start opens completed'
    Wait-Condition {[CodexDualTests.HostAutomation]::Responds($main.Handle)} 'dual open completed'
    foreach($instance in $config.instances){
        $status=Get-InstanceStatus $config $instance
        Check ($status.State -eq 'Running') ('Both-open button starts '+$instance.role+' fixture')
        $fixtureProcesses+=$status.Process
        # The repeat-open flow below specifically tests multi-window selection.
        Wait-Condition {@(Get-InstanceWindows $instance $status.Process|Where-Object {$_.Visible}).Count -eq 2} ('both fixture windows ready '+$instance.role)
    }
    Click-Button $element '同时打开两边'
    Wait-Condition {(Find-Window '选择要显示的窗口').Count -eq 1} 'repeat official selector'
    $cancelHandle=(Find-Window '选择要显示的窗口')[0].Handle
    [CodexDualTests.HostAutomation]::CloseLikeUser($cancelHandle)
    Wait-Condition {@((Find-Window '选择要显示的窗口')|Where-Object {$_.Handle -ne $cancelHandle}).Count -eq 1} 'API selector follows cancellation'
    Click-Button (Find-Window '选择要显示的窗口')[0].Handle '显示选中窗口'
    Wait-Condition {(Find-Window '选择要显示的窗口').Count -eq 0} 'repeat API selected'
    foreach($fixture in $fixtureProcesses){Check (Test-ExpectedProcessAlive $fixture) 'Repeat dual open retains the original fixture process'}
    Check (@(Get-ProcessSnapshot|Where-Object {Test-SamePath $_.Path $fixtureExe}).Count -eq 2) 'Repeat dual open creates no duplicate process'
    Check (@([CodexDualTests.HostAutomation]::Children($element,'BUTTON','常用目录…')).Count -eq 2) 'Each environment exposes its own folder menu'
    Wait-Condition {(Test-Path -LiteralPath $workerStatusPath) -and (Get-Content -LiteralPath $workerStatusPath -Raw|ConvertFrom-Json).state -eq 'running'} 'notification worker ready'
    $complete=@{type='event_msg';payload=@{type='task_complete';turn_id=[Guid]::NewGuid().ToString();last_agent_message='DO-NOT-SHOW-PRIVATE-COMPLETION'}}|ConvertTo-Json -Compress
    [IO.File]::AppendAllText($completionLog,$complete+"`n",(New-Object Text.UTF8Encoding($false)))
    Wait-Condition {[CodexDualTests.HostAutomation]::FindDialog($process.Id,'API 环境 · 任务完成') -ne 0} 'completion card from worker'
    $completionHandle=[CodexDualTests.HostAutomation]::FindDialog($process.Id,'API 环境 · 任务完成')
    Check (-not ([CodexDualTests.HostAutomation]::Describe($process.Id)).Contains('DO-NOT-SHOW-PRIVATE-COMPLETION')) 'Background log event produces correct API card without response body'
    Click-Button $completionHandle '查看任务'
    Wait-Condition {(Find-Window '选择要显示的窗口').Count -eq 1} 'completion task opens correct fixture environment'
    Click-Button (Find-Window '选择要显示的窗口')[0].Handle '显示选中窗口'
    Wait-Condition {([CodexDualTests.HostAutomation]::Describe($process.Id)).Contains('此程序入口未确认支持任务链接')} 'unsupported fixture reports instance-only fallback'
    Check ((Get-InstanceStatus $config $config.instances[1]).Process.Id -eq $fixtureProcesses[1].Id) 'Task card falls back to original API fixture without invoking global protocol'
    Wait-Condition {[CodexDualTests.HostAutomation]::FindDialog($process.Id,'API 环境 · 任务完成') -eq 0} 'completion card dismissed'
    Click-Button $element '检查环境'
    Wait-Condition {(Find-Window '环境检查 · 脱敏报告').Count -eq 1} 'redacted diagnostics visible'
    $diagnosticHandle=(Find-Window '环境检查 · 脱敏报告')[0].Handle
    Check ([CodexDualTests.HostAutomation]::Responds($diagnosticHandle)) 'Diagnostics responds while background report is loading'
    Wait-Condition {([CodexDualTests.HostAutomation]::Describe($process.Id)).Contains('可分享诊断报告')} 'background diagnostic report ready'
    $reportControls=[CodexDualTests.HostAutomation]::Describe($process.Id)
    Check ($reportControls.Contains('可分享诊断报告') -and -not $reportControls.Contains('fixture-host-no-real-key') -and -not $reportControls.Contains($root)) 'Actual diagnostics dialog renders without fixture secrets or paths'
    Check (@([CodexDualTests.HostAutomation]::Children($diagnosticHandle,'BUTTON','复制报告')).Count -eq 1 -and @([CodexDualTests.HostAutomation]::Children($diagnosticHandle,'BUTTON','导出报告…')).Count -eq 1) 'Diagnostics exposes copy and export controls'
    Click-Button $diagnosticHandle '关闭'
    Wait-Condition {(Find-Window '环境检查 · 脱敏报告').Count -eq 0} 'diagnostics closed'
    Click-Button $element '改名'
    Wait-Condition {(Find-Window '修改显示名称').Count -eq 1} 'rename dialog'
    $dialog=Get-Element (Find-Window '修改显示名称')[0].Handle
    Wait-Condition {@([CodexDualTests.HostAutomation]::Children($dialog,'EDIT',$null)).Count -eq 1} 'rename input available'
    $edit=@([CodexDualTests.HostAutomation]::Children($dialog,'EDIT',$null))[0]
    [CodexDualTests.HostAutomation]::SetText($edit,'规划专用')
    Click-Button $dialog '保存'
    Wait-Condition {(Get-InstanceDisplayName $config.instances[0] (Read-ControllerPreferences $config)) -eq '规划专用'} 'name saved'
    Check $true 'Real rename dialog saves name through its button'
    Click-Button $element '改名';Wait-Condition {(Find-Window '修改显示名称').Count -eq 1} 'rename reopen'
    Click-Button (Get-Element (Find-Window '修改显示名称')[0].Handle) '恢复默认'
    Wait-Condition {(Get-InstanceDisplayName $config.instances[0] (Read-ControllerPreferences $config)) -eq '官方环境'} 'name reset'
    Check $true 'Real reset button restores default name'
    $configure=Start-TestHost ('--configure --config "'+$configPath+'"')
    try{Check ($configure.WaitForExit(12000) -and $configure.ExitCode -eq 0) 'Configure entry forwards without starting another controller'}finally{$configure.Dispose()}
    Wait-Condition {(Find-Window 'API 渠道管理').Count -eq 1} 'API manager visible'
    # Visibility can precede the end of ShowDialog initialization; wait for input readiness.
    [void]$process.WaitForInputIdle(5000)
    Start-Sleep -Milliseconds 400
    $apiWindow=(Find-Window 'API 渠道管理')[0];$apiElement=Get-Element $apiWindow.Handle
    Click-Button $apiElement 'CCS 接入'
    Wait-Condition {@([CodexDualTests.HostAutomation]::Children($apiElement,'BUTTON','交给 CCS 管理')).Count -eq 1} 'CCS page ready'
    Check (@([CodexDualTests.HostAutomation]::Children($apiElement,'BUTTON','交给 CCS 管理')).Count -eq 1) 'App-style tabs switch to CCS page'
    Click-Button $apiElement '备份恢复'
    Wait-Condition {@([CodexDualTests.HostAutomation]::Children($apiElement,'BUTTON','备份当前配置')).Count -eq 1} 'Backup page ready'
    Check (@([CodexDualTests.HostAutomation]::Children($apiElement,'BUTTON','备份当前配置')).Count -eq 1) 'App-style tabs switch to backup page'
    Click-Button $apiElement '渠道方案'
    Wait-Condition {@([CodexDualTests.HostAutomation]::Children($apiElement,'BUTTON','新增')).Count -eq 1} 'Channel page ready'
    Click-Button $apiElement '新增'
    $visibleEdits=@([CodexDualTests.HostAutomation]::Children($apiElement,'EDIT',$null))
    Check ($visibleEdits.Count -eq 4) 'API manager exposes name, endpoint, model and password fields'
    # Fill only three public fixture fields, then cancel the draft by closing the dialog.
    [CodexDualTests.HostAutomation]::SetText($visibleEdits[0],'界面夹具')
    [CodexDualTests.HostAutomation]::CloseLikeUser($apiWindow.Handle)
    Wait-Condition {(Find-Window 'API 渠道管理').Count -eq 0} 'API manager closed'
    Click-Button $main.Handle '×'
    Wait-Condition {(Find-Window $panelPattern).Count -eq 0} 'panel hidden to tray'
    Check (-not $process.HasExited) 'Closing panel keeps compiled controller running'
    $again=Start-TestHost ('--config "'+$configPath+'"')
    try{Check ($again.WaitForExit(12000) -and $again.ExitCode -eq 0) 'Restore request exits after forwarding'}finally{if(-not $again.HasExited){$again.Kill();$again.WaitForExit()};$again.Dispose()}
    Wait-Condition {(Find-Window $panelPattern).Count -eq 1} 'panel restored'
    Check (@(Get-ProcessSnapshot|Where-Object {Test-SamePath $_.Path $exe}).Count -eq 1) 'Repeated taskbar-style launch keeps one compiled host'
    # Exercise real instance exit buttons against disposable GUI processes only.
    $officialFixture=$config.instances[0]
    Write-AtomicText (Join-Path $officialFixture.profile 'stubborn.fixture') ''
    $stubborn=Start-OrFindInstance $config $officialFixture;$fixtureProcesses+=$stubborn
    $other=Start-OrFindInstance $config $config.instances[1];$fixtureProcesses+=$other
    foreach($forceAnswer in @(7,6)){
        Click-Button $main.Handle '退出…'
        Wait-Condition {([CodexDualTests.HostAutomation]::FindDialog($process.Id,'确认退出')) -ne 0} 'exit confirmation'
        [CodexDualTests.HostAutomation]::Answer([CodexDualTests.HostAutomation]::FindDialog($process.Id,'确认退出'),6)
        $exitWatch=[Diagnostics.Stopwatch]::StartNew()
        Wait-Condition {(Find-Window '正在退出').Count -eq 1} 'progress window'
        $progressWindow=(Find-Window '正在退出')[0]
        Check ([CodexDualTests.HostAutomation]::Responds($progressWindow.Handle)) 'Progress window responds during graceful exit wait'
        Wait-Condition {([CodexDualTests.HostAutomation]::FindDialog($process.Id,'正常退出未完成')) -ne 0} 'force confirmation'
        $exitWatch.Stop()
        Check ($exitWatch.ElapsedMilliseconds -lt 7000) 'Close-to-tray reaches confirmation without the old ten-second freeze'
        [CodexDualTests.HostAutomation]::Answer([CodexDualTests.HostAutomation]::FindDialog($process.Id,'正常退出未完成'),$forceAnswer)
        Wait-Condition {([CodexDualTests.HostAutomation]::FindDialog($process.Id,'退出结果')) -ne 0} 'exit results'
        Check ((Test-ExpectedProcessAlive $stubborn) -eq ($forceAnswer -eq 7)) 'Force decline preserves the fixture; approval ends it'
        Check (Test-ExpectedProcessAlive $other) 'Other environment survives the full exit flow'
        [CodexDualTests.HostAutomation]::Answer([CodexDualTests.HostAutomation]::FindDialog($process.Id,'退出结果'),1)
        Wait-Condition {([CodexDualTests.HostAutomation]::FindDialog($process.Id,'退出结果')) -eq 0} 'result dismissed'
        Start-Sleep -Milliseconds 600
    }
    # A normal close must return successfully even if the first window ends the process.
    $buttons=@([CodexDualTests.HostAutomation]::Children($main.Handle,'BUTTON','退出…'))
    [CodexDualTests.HostAutomation]::Click($buttons[1])
    Wait-Condition {([CodexDualTests.HostAutomation]::FindDialog($process.Id,'确认退出')) -ne 0} 'API exit confirmation'
    [CodexDualTests.HostAutomation]::Answer([CodexDualTests.HostAutomation]::FindDialog($process.Id,'确认退出'),6)
    Wait-Condition {([CodexDualTests.HostAutomation]::FindDialog($process.Id,'退出结果')) -ne 0} 'normal exit result'
    Check (-not (Test-ExpectedProcessAlive $other)) 'Normal multi-window exit completes without a force prompt'
    [CodexDualTests.HostAutomation]::Answer([CodexDualTests.HostAutomation]::FindDialog($process.Id,'退出结果'),1)
    Start-Sleep -Milliseconds 600
    $element=Get-Element (Find-Window $panelPattern)[0].Handle
    Click-Button $element '退出工具'
    Check ($process.WaitForExit(12000)) 'Exit button ends only test controller'
    Check ((Get-Content -LiteralPath $workerStatusPath -Raw|ConvertFrom-Json).state -eq 'stopped') 'Controller exit stops its notification worker cleanly'
    $after=Get-ProcessSnapshot
    Check (@($original|Where-Object {$saved=$_;@($after|Where-Object {Test-ProcessIdentity $saved $_}).Count -ne 1}).Count -eq 0) 'Original Codex processes retained throughout EXE UI test'
}catch{if($process -and -not $process.HasExited){Write-Output ([CodexDualTests.HostAutomation]::Describe($process.Id))};throw}
finally{if($process){if(-not $process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()};foreach($fixture in @(Get-ProcessSnapshot|Where-Object {Test-SamePath $_.Path $fixtureExe})){Stop-VerifiedProcess $fixture}}
Write-Output "PASSED: $script:passed compiled-host checks. Output: $root"
