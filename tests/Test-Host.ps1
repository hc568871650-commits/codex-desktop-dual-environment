$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
Add-Type -Path "$PSScriptRoot\HostAutomation.cs"
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$guard=New-Object Threading.Mutex($false,('Local\CodexDual.Controller.'+$sid));$held=$false
try{try{$held=$guard.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(-not $held){throw '请在没有日常控制器运行的独立测试会话中运行 Test-Host。不会关闭现有控制器。'}}finally{if($held){$guard.ReleaseMutex()};$guard.Dispose()}
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('host-'+[Guid]::NewGuid().ToString('N')+' space 中文')
$install=Join-Path $root 'Tool';$data=Join-Path $root 'Data';$official=Join-Path $root 'Official'
$fake=ConvertTo-SecureString 'fixture-host-no-real-key' -AsPlainText -Force
[void][IO.Directory]::CreateDirectory($root)
$fixtureExe=Join-Path $root 'Fixture.exe'
Add-Type -Path "$PSScriptRoot\Fixture.cs" -ReferencedAssemblies System.Windows.Forms,System.Drawing -OutputAssembly $fixtureExe -OutputType WindowsApplication
& "$PSScriptRoot\..\scripts\Install.ps1" -InstallDirectory $install -DataDirectory $data -OfficialHome $official -OfficialProfile (Join-Path $root 'OfficialProfile') -Executable $fixtureExe -BaseUrl 'https://example.com/v1' -Model 'example-model' -ApiKey $fake -NoShortcuts
$exe=Join-Path $install 'CodexDualController.exe';$configPath=Join-Path $install 'instances.local.json';$config=Read-ControllerConfig $configPath
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
    Wait-Condition {(Find-Window '*0.3*').Count -eq 1} 'main panel visible'
    $main=(Find-Window '*0.3*')[0];$element=Get-Element $main.Handle
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
    Click-Button $apiElement '新增'
    $visibleEdits=@([CodexDualTests.HostAutomation]::Children($apiElement,'EDIT',$null))
    Check ($visibleEdits.Count -eq 4) 'API manager exposes name, endpoint, model and password fields'
    # Fill only three public fixture fields, then cancel the draft by closing the dialog.
    [CodexDualTests.HostAutomation]::SetText($visibleEdits[0],'界面夹具')
    [CodexDualTests.HostAutomation]::CloseLikeUser($apiWindow.Handle)
    Wait-Condition {(Find-Window 'API 渠道管理').Count -eq 0} 'API manager closed'
    [CodexDualTests.HostAutomation]::CloseLikeUser($main.Handle)
    Wait-Condition {(Find-Window '*0.3*').Count -eq 0} 'panel hidden to tray'
    Check (-not $process.HasExited) 'Closing panel keeps compiled controller running'
    $again=Start-TestHost ('--config "'+$configPath+'"')
    try{Check ($again.WaitForExit(12000) -and $again.ExitCode -eq 0) 'Restore request exits after forwarding'}finally{if(-not $again.HasExited){$again.Kill();$again.WaitForExit()};$again.Dispose()}
    Wait-Condition {(Find-Window '*0.3*').Count -eq 1} 'panel restored'
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
    $element=Get-Element (Find-Window '*0.3*')[0].Handle
    Click-Button $element '退出工具'
    Check ($process.WaitForExit(12000)) 'Exit button ends only test controller'
    $after=Get-ProcessSnapshot
    Check (@($original|Where-Object {$saved=$_;@($after|Where-Object {Test-ProcessIdentity $saved $_}).Count -ne 1}).Count -eq 0) 'Original Codex processes retained throughout EXE UI test'
}catch{if($process -and -not $process.HasExited){Write-Output ([CodexDualTests.HostAutomation]::Describe($process.Id))};throw}
finally{if($process){if(-not $process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()};foreach($fixture in $fixtureProcesses){Stop-VerifiedProcess $fixture}}
Write-Output "PASSED: $script:passed compiled-host checks. Output: $root"
