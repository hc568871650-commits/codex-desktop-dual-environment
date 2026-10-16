$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\..\src\Instances.ps1"
. "$PSScriptRoot\..\src\Panel.ps1"

# Exercise the real close state machine and real UI controls. Every process,
# confirmation and wait boundary below is mocked; no process is started or killed.
$script:passed=0
function Check($Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:passed++;Write-Output "PASS: $Message"}
$instance=[pscustomobject]@{id='exit-fixture';role='api'}
$config=[pscustomobject]@{instances=@($instance)}
$script:preferences=@{}
$script:apiInstance=$instance
$panel=New-Object Windows.Forms.Form
$script:feedback=New-Object Windows.Forms.Label
$panel.Controls.Add($script:feedback)
$closeButton=New-Object Windows.Forms.Button
$closeButton.Text='退出…';$panel.Controls.Add($closeButton)
$openButton=New-Object Windows.Forms.Button
$panel.Controls.Add($openButton)
$closeMenu=New-Object Windows.Forms.ToolStripMenuItem
$openMenu=New-Object Windows.Forms.ToolStripMenuItem
$script:instanceCloseButtons=@{api=$closeButton}
$script:closeMenus=@{api=$closeMenu}
$script:openMenus=@{api=$openMenu}
$script:exitDetails=$null
$closeMenu.Text='退出 测试 API…'
$script:confirmations=New-Object 'Collections.Generic.List[string]'
$script:waitTimeouts=New-Object 'Collections.Generic.List[int]'
$script:forcedIdentities=New-Object 'Collections.Generic.List[object]'
$script:currentProcess=[pscustomobject]@{Id=900001;Started=100;Path='C:\ExitFixture\desktop.exe';Command='desktop.exe --fixture'}

function Get-InstanceDisplayName($Instance,$Preferences){return '测试 API'}
function Invoke-InstanceLocked($Instance,[scriptblock]$Action){& $Action}
function Assert-NotCurrentHost($Process){}
function Get-InstanceStatus($Config,$Instance){return [pscustomobject]@{State=$script:state;Process=$script:currentProcess}}
function Confirm-InstanceExit([string]$Label){$script:confirmations.Add($Label);return $script:confirmAnswer}
function Show-ControlPanel([switch]$WithoutFocus){$script:showCount++}
function Get-ProcessSnapshot(){return $script:currentProcess}
function Get-OwnedDesktopChildren($Process,$Snapshot){return $Process}
function Request-InstanceClose($Instance,$Process){throw 'Direct exit must not request graceful close.'}
function Stop-InstanceForced($Instance,$Process,[switch]$UserConfirmed){
    if(-not $UserConfirmed){throw 'Force was called without explicit confirmation.'}
    if(-not $script:openBusy){throw 'Stop must run with actions disabled.'}
    $script:forceCount++;$script:forcedIdentities.Add($Process);return $Process
}
function Wait-ExpectedProcessExitUi($Expected,[string]$Message,[int]$TimeoutMilliseconds,[switch]$PassThru){
    if(-not $script:openBusy -or $closeButton.Enabled -or $openButton.Enabled -or $closeMenu.Enabled -or $openMenu.Enabled){throw 'Actions must remain disabled while waiting.'}
    if($script:forceCount -ne $script:waitTimeouts.Count+1){throw 'Each wait must follow exactly one direct stop.'}
    $script:waitTimeouts.Add($TimeoutMilliseconds)
    Set-UiMessage $Message
    if($script:waitExited){$script:state='Stopped'}
    return $script:waitExited
}
function Get-ExitResiduals($Before,$Owned){return @()}
function Apply-ApiProfile($Config,$Instance,$ProfileId){$script:applyCount++;throw 'A running instance must not reach profile application.'}
function Reset-Scenario {
    $script:state='Running';$script:confirmAnswer=$true;$script:waitExited=$true
    $script:requestCount=0;$script:forceCount=0;$script:showCount=0;$script:applyCount=0
    $script:confirmations.Clear();$script:waitTimeouts.Clear();$script:forcedIdentities.Clear()
    $script:currentProcess=[pscustomobject]@{Id=900001;Started=100;Path='C:\ExitFixture\desktop.exe';Command='desktop.exe --fixture'}
    $script:feedback.Text='';$script:openBusy=$false
}

try {
    Reset-Scenario;$script:confirmAnswer=$false
    Close-Instance $instance
    Check ($script:confirmations.Count -eq 1 -and $script:confirmations[0] -eq '测试 API') 'Exit asks for one environment confirmation'
    Check ($script:forceCount -eq 0 -and $script:waitTimeouts.Count -eq 0) 'Cancellation neither kills nor waits'
    Check ($script:state -eq 'Running' -and -not $script:openBusy) 'Cancellation retains running state and controls'

    Reset-Scenario
    Close-Instance $instance
    Check ($script:forceCount -eq 1 -and $script:confirmations.Count -eq 1) 'First confirmation directly stops once without graceful close or second confirmation'
    Check (Test-ProcessIdentity $script:forcedIdentities[0] $script:currentProcess) 'Direct stop receives the captured process identity'
    Check ($script:waitTimeouts.Count -eq 1 -and $script:waitTimeouts[0] -le 2000) 'Direct stop uses a bounded post-stop wait only'
    Check ($script:feedback.Text -eq '测试 API 已退出') 'Success reports inline'
    Check (-not $script:openBusy -and $closeButton.Enabled -and $openButton.Enabled -and $closeMenu.Enabled -and $openMenu.Enabled) 'Success restores action controls'
    Close-Instance $instance
    Check ($script:forceCount -eq 1 -and $script:confirmations.Count -eq 1 -and $script:waitTimeouts.Count -eq 1) 'Already stopped repeat performs no confirmation, kill or wait'

    Reset-Scenario;$script:state='Stopped'
    Close-Instance $instance
    Check ($script:forceCount -eq 0 -and $script:confirmations.Count -eq 0 -and $script:waitTimeouts.Count -eq 0) 'Initially stopped environment performs no process operation'

    Reset-Scenario;$script:waitExited=$false
    Close-Instance $instance
    Check ($script:forceCount -eq 1 -and $script:confirmations.Count -eq 1 -and $script:waitTimeouts.Count -eq 1) 'Timeout never retries stop or adds confirmation'
    Check ($script:waitTimeouts[0] -le 2000 -and $script:feedback.Text -eq '测试 API 退出尚未完成，请稍后检查状态。') 'Timeout reports only incomplete exit after bounded post-stop wait'
    Check ($closeButton.Text -eq '退出…' -and $closeMenu.Text -eq '退出 测试 API…') 'Timeout never exposes a force action'
    Check (-not $script:openBusy -and $closeButton.Enabled -and $openButton.Enabled -and $closeMenu.Enabled -and $openMenu.Enabled) 'Timeout restores action controls'
    # Deliberately reuse the same PID with a later start time.
    $script:currentProcess=[pscustomobject]@{Id=900001;Started=200;Path='C:\ExitFixture\desktop.exe';Command='desktop.exe --fixture'}
    $script:waitExited=$true
    Close-Instance $instance
    Check ($script:forceCount -eq 2 -and $script:confirmations.Count -eq 2 -and (Test-ProcessIdentity $script:forcedIdentities[1] $script:currentProcess) -and -not (Test-ProcessIdentity $script:forcedIdentities[0] $script:currentProcess)) 'Explicit later exit confirms and targets the current identity'

    Reset-Scenario;$script:confirmAnswer=$false
    Apply-SelectedProfile ([pscustomobject]@{id='fixture-profile'}) $true
    Check ($script:confirmations.Count -eq 1 -and $script:forceCount -eq 0) 'Channel restart cancellation performs no stop'
    Check ($script:applyCount -eq 0 -and $script:feedback.Text.Contains('渠道未应用')) 'Cancelled exit protects channel configuration'

    Reset-Scenario;$script:waitExited=$false
    Apply-SelectedProfile ([pscustomobject]@{id='fixture-profile'}) $true
    Check ($script:confirmations.Count -eq 1 -and $script:forceCount -eq 1 -and $script:waitTimeouts.Count -eq 1) 'Channel restart directly stops once and never retries after timeout'
    Check ($script:applyCount -eq 0 -and $script:feedback.Text.Contains('渠道未应用')) 'Incomplete exit prevents channel application'
    Check (-not $script:openBusy -and $closeButton.Enabled -and $closeMenu.Enabled -and $closeButton.Text -eq '退出…') 'Channel timeout restores controls without a force option'
} finally {
    $panel.Dispose();$closeMenu.Dispose();$openMenu.Dispose()
}
if($script:passed -ne 20){throw 'Exit flow checks were skipped.'}
Write-Output "PASSED: $script:passed mocked exit-flow checks; no process operations performed"
