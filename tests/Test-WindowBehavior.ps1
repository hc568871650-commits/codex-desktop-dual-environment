$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
    throw 'Run this test in Windows PowerShell 5.1 with -STA.'
}
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('window-behavior-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$log=Join-Path $root 'test.log'
Start-Transcript -Path $log | Out-Null
$script:passed=0;$script:failed=0;$windows=$null
try {
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing,System.Web.Extensions
    $windows=New-Object 'Collections.Generic.List[System.Windows.Forms.Form]'
    . "$PSScriptRoot\..\src\Instances.ps1"
    Add-Type -Path @("$PSScriptRoot\..\src\UiTheme.cs","$PSScriptRoot\..\src\QuestionWindow.cs") -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WindowBehaviorProbe {
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr handle);
 [DllImport("user32.dll",EntryPoint="GetWindowLongW")] static extern int GetWindowLong(IntPtr handle,int index);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr handle);
 public static bool IsTopMost(IntPtr handle) { return (GetWindowLong(handle,-20)&8)!=0; }
 public static bool IsNoActivate(IntPtr handle) { return (GetWindowLong(handle,-20)&0x08000000)!=0; }
}
'@
    function Check($value,[string]$message) {
        if($value){$script:passed++;Write-Output "PASS: $message"}
        else{$script:failed++;Write-Output "FAIL: $message"}
    }
    function Pump {
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while($clock.ElapsedMilliseconds -lt 120){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    }
    function Own-Foreground($form) {
        $form.Show();$form.Activate();[void][WindowBehaviorProbe]::SetForegroundWindow($form.Handle);Pump
        if([WindowBehaviorProbe]::GetForegroundWindow() -ne $form.Handle){
            throw 'Fixture could not establish its own foreground window; behavior results would be inconclusive.'
        }
    }
    function Check-Presentation($form,$focus,$overlay,[string]$label) {
        Pump
        $expected=if($focus){$form.Handle}else{$anchor.Handle}
        $actual=[WindowBehaviorProbe]::GetForegroundWindow()
        Check ($actual -eq $expected) "$label foreground (focus=$focus, expected=$expected, actual=$actual, subject=$($form.Handle), anchor=$($anchor.Handle))"
        Check ([WindowBehaviorProbe]::IsTopMost($form.Handle) -eq $overlay) "$label native WS_EX_TOPMOST (overlay=$overlay)"
        Check ($form.TopMost -eq $overlay -and $form.ShowWithoutFocus -eq (-not $focus)) "$label managed policy"
        Check ($form.Visible -and -not [WindowBehaviorProbe]::IsIconic($form.Handle)) "$label visible and restored"
    }
    $config=[pscustomobject]@{stateDirectory=(Join-Path $root 'preferences')}
    $defaults=Get-WindowBehavior $null
    Check ($defaults.panelMode -eq 'focus' -and -not $defaults.panelOverlay -and $defaults.questionMode -eq 'notice' -and $defaults.questionOverlay) 'Missing preferences use focus/ordinary panel and notice/overlay questions'
    $saved=Read-ControllerPreferences $config
    $saved.names.fixture='preserved';$saved.panel=@{x=17;y=29};$saved.ccsExecutable='fixture.exe';$saved.ccsSettingsPath='fixture.json';$saved.pendingApi=@{instanceId='fixture';model='fixture-model'};$saved.appearance=@{mode='light';accent='blue'}
    Save-ControllerPreferences $config $saved
    foreach($panelMode in @('focus','passive')){foreach($questionMode in @('notice','passive','focus')){foreach($overlay in @($false,$true)){
        $returned=Set-WindowBehavior $config $panelMode $overlay $questionMode (-not $overlay)
        $read=Read-ControllerPreferences $config;$policy=Get-WindowBehavior $read
        Check ($policy.panelMode -eq $panelMode -and $policy.panelOverlay -eq $overlay -and $policy.questionMode -eq $questionMode -and $policy.questionOverlay -eq (-not $overlay)) "Preference round trip: $panelMode/$questionMode/$overlay"
        Check ($returned.windowBehavior.panelMode -eq $panelMode -and $returned.windowBehavior.questionOverlay -eq (-not $overlay)) 'Setter returns saved policy'
        Check ($read.names.fixture -eq 'preserved' -and $read.panel.x -eq 17 -and $read.panel.y -eq 29 -and $read.ccsExecutable -eq 'fixture.exe' -and $read.ccsSettingsPath -eq 'fixture.json' -and $read.pendingApi.model -eq 'fixture-model' -and $read.appearance.mode -eq 'light' -and $read.appearance.accent -eq 'blue') 'Policy write preserves unrelated preferences'
    }}}
    $saved=Read-ControllerPreferences $config
    $saved.windowBehavior=@{panelMode='bad';questionMode='bad';panelOverlay='true';questionOverlay=0}
    Save-ControllerPreferences $config $saved
    $read=Read-ControllerPreferences $config;$fallback=Get-WindowBehavior $read
    Check ($fallback.panelMode -eq 'focus' -and -not $fallback.panelOverlay -and $fallback.questionMode -eq 'notice' -and $fallback.questionOverlay -and $read.names.fixture -eq 'preserved') 'Invalid modes and non-boolean overlay values fall back without discarding preferences'
    foreach($invalid in @(@('bad','notice'),@('focus','bad'))){
        $before=[IO.File]::ReadAllText((Get-ControllerPreferencesPath $config));$rejected=$false
        try{Set-WindowBehavior $config $invalid[0] $true $invalid[1] $false | Out-Null}catch{$rejected=$true}
        Check ($rejected -and [IO.File]::ReadAllText((Get-ControllerPreferencesPath $config)) -eq $before) 'Invalid setter input rejects without rewriting saved preferences'
    }
    $anchor=New-Object Windows.Forms.Form;$windows.Add($anchor)
    $anchor.Text='Window behavior test - foreground fixture';$anchor.StartPosition='Manual';$anchor.SetBounds(30,30,280,150)
    Own-Foreground $anchor
    foreach($focus in @($false,$true)){foreach($overlay in @($false,$true)){
        $form=New-Object CodexDual.ShellForm;$windows.Add($form)
        $form.Text='Window behavior test - subject';$form.StartPosition='Manual';$form.SetBounds(330,30,280,150)
        $input=New-Object Windows.Forms.TextBox;$input.SetBounds(10,40,200,25);$form.Controls.Add($input)
        Own-Foreground $anchor
        $form.Present($focus,$overlay);Check-Presentation $form $focus $overlay 'First Present'
        Own-Foreground $anchor
        $form.Present($focus,$overlay);Check-Presentation $form $focus $overlay 'Visible repeat Present'
        $form.Hide();Own-Foreground $anchor
        $form.Present($focus,$overlay);Check-Presentation $form $focus $overlay 'Hidden reopen Present'
        $form.WindowState='Minimized';Pump;Own-Foreground $anchor
        $form.Present($focus,$overlay);Check-Presentation $form $focus $overlay 'Minimized restore Present'
        $form.Present($true,$overlay);Pump
        Check ($input.Focus() -and $input.Focused -and [WindowBehaviorProbe]::GetForegroundWindow() -eq $form.Handle) 'Previously passive window permits input focus after activation'
        Check (-not [WindowBehaviorProbe]::IsNoActivate($form.Handle)) 'No permanent WS_EX_NOACTIVATE prevents user interaction'
        Own-Foreground $anchor
        $form.Present($false,(-not $overlay));Check-Presentation $form $false (-not $overlay) 'Live overlay toggle without activation'
        $form.Dispose()
    }}
    $passive=New-Object CodexDual.ShellForm;$windows.Add($passive)
    $passive.ShowWithoutFocus=$true;$passive.StartPosition='Manual';$passive.SetBounds(330,200,280,150)
    Own-Foreground $anchor;$passive.Show();Pump
    Check ([WindowBehaviorProbe]::GetForegroundWindow() -eq $anchor.Handle -and -not [WindowBehaviorProbe]::IsTopMost($passive.Handle)) 'Direct passive Show preserves foreground and ordinary layer'
    $passive.Dispose()
    $question=New-Object CodexDual.QuestionWindow;$windows.Add($question)
    Check ($question -is [CodexDual.ShellForm] -and $question.ShowWithoutFocus -and $question.TopMost) 'QuestionWindow inherits ShellForm and defaults to passive overlay'
    Write-Output "Question before first Show: IsHandleCreated=$($question.IsHandleCreated); Visible=$($question.Visible); ShowWithoutFocus=$($question.ShowWithoutFocus); TopMost=$($question.TopMost)"
    Own-Foreground $anchor;$question.Show();Pump
    $actual=[WindowBehaviorProbe]::GetForegroundWindow()
    Check ($actual -eq $anchor.Handle -and [WindowBehaviorProbe]::IsTopMost($question.Handle)) "Question first direct Show preserves foreground with native topmost (actual=$actual, subject=$($question.Handle), anchor=$($anchor.Handle), nativeTopmost=$([WindowBehaviorProbe]::IsTopMost($question.Handle)))"
    $question.Hide();Own-Foreground $anchor;$question.Present($false,$false)
    Check-Presentation $question $false $false 'Question passive ordinary reopen'
    $question.Present($true,$true);Check-Presentation $question $true $true 'Question focus overlay'
    Write-Output "CHECKS: $($script:passed+$script:failed); PASSED: $script:passed; FAILED: $script:failed"
    if($script:failed){throw "$script:failed window behavior checks failed. See $log"}
} finally {
    if($windows){foreach($window in $windows){if(-not $window.IsDisposed){$window.Dispose()}}}
    Write-Output "LOG: $log"
    Stop-Transcript | Out-Null
}
