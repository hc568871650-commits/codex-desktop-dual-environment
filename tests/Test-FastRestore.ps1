$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\..\src\Panel.ps1"

$script:passed=0
function Check($condition,[string]$message) {
    if(-not $condition){throw "FAIL: $message"}
    $script:passed++
    Write-Output "PASS: $message"
}
function Wait-For([scriptblock]$condition,[string]$message) {
    for($attempt=0;$attempt -lt 60;$attempt++) {
        if(& $condition){return}
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out: $message"
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FastRestoreWindowState {
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr handle);
}
'@

$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('fast-restore-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$exe=Join-Path $root 'FastRestoreFixture.exe'
Add-Type -TypeDefinition @'
using System;
using System.Windows.Forms;
class FastRestoreFixture {
 [STAThread] static void Main(string[] args) {
  string mode=Array.IndexOf(args,"--hidden")>=0?"hidden":Array.IndexOf(args,"--multiple")>=0?"multiple":Array.IndexOf(args,"--tool")>=0?"tool":"normal";
  var main=new Form {Text="Fast restore main",Width=360,Height=180};
  var second=new Form {Text="Fast restore second",Width=360,Height=180};
  var tool=new Form {Text="Fast restore tool",Width=360,Height=180,FormBorderStyle=FormBorderStyle.FixedToolWindow,TopMost=true,ShowInTaskbar=false};
  main.Shown+=(s,e)=>{
   if(mode=="hidden")main.BeginInvoke((Action)(()=>main.Hide()));
   else if(mode=="multiple")second.Show();
   else if(mode=="tool")tool.Show();
   else main.WindowState=FormWindowState.Minimized;
  };
  main.FormClosed+=(s,e)=>Application.ExitThread();
  Application.Run(main);
 }
}
'@ -ReferencedAssemblies System.Windows.Forms,System.Drawing -OutputAssembly $exe -OutputType WindowsApplication

$started=@()
function Start-Fixture([string]$label,[string]$mode) {
    $fixtureHome=Join-Path $root ($label+'-home');$fixtureProfile=Join-Path $root ($label+'-profile')
    [void][IO.Directory]::CreateDirectory($fixtureHome);[void][IO.Directory]::CreateDirectory($fixtureProfile)
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$exe;$info.UseShellExecute=$false;$info.WorkingDirectory=$root
    $info.Arguments='--user-data-dir="'+$fixtureProfile+'"'+$(if($mode){' --'+$mode}else{''})
    $info.EnvironmentVariables['CODEX_HOME']=$fixtureHome
    $pidValue=[CodexDual.Native]::StartDetached($info)
    Wait-For {@(Get-ProcessSnapshotById $pidValue).Count -eq 1 -and @([CodexDual.Native]::Windows($pidValue)).Count -gt 0} ($label+' window')
    $snapshot=@(Get-ProcessSnapshotById $pidValue)[0]
    $script:started+=,$snapshot
    return [pscustomobject]@{Home=$fixtureHome;Profile=$fixtureProfile;Process=$snapshot}
}
function Focus($fixture,$process=$null) {
    if(-not $process){$process=$fixture.Process}
    return [CodexDual.Native]::FocusKnownVisible($process.Id,[long]$process.Started,$process.Path,$process.Command,$fixture.Home,$fixture.Profile)
}
try {
    $official=Start-Fixture 'official' ''
    $api=Start-Fixture 'api' ''
    Check ($official.Process.Id -ne $api.Process.Id -and $official.Home -ne $api.Home -and $official.Profile -ne $api.Profile) 'Two independent fixture processes and environments'
    Wait-For {
        $w=@([CodexDual.Native]::Windows($api.Process.Id)|Where-Object {$_.Visible})
        $w.Count -eq 1 -and [FastRestoreWindowState]::IsIconic([IntPtr]$w[0].Handle)
    } 'API fixture minimized'
    Check (-not [CodexDual.Native]::IsInstanceForeground($exe,$api.Home,$api.Profile)) 'Minimized API does not suppress notifications'
    $outcome=Focus $api
    Wait-For {
        $w=@([CodexDual.Native]::Windows($api.Process.Id)|Where-Object {$_.Visible})
        $w.Count -eq 1 -and -not [FastRestoreWindowState]::IsIconic([IntPtr]$w[0].Handle)
    } 'API fixture restored'
    Check ($outcome -in @('Shown','Running') -and (Test-ExpectedProcessAlive $api.Process)) 'Minimized API restores without changing PID or identity'
    Check (Test-ExpectedProcessAlive $official.Process) 'API focus leaves the independent official instance alive'
    Wait-For {[CodexDual.Native]::IsInstanceForeground($exe,$api.Home,$api.Profile)} 'API fixture foreground'
    Check ([CodexDual.Native]::IsInstanceForeground($exe,$api.Home,$api.Profile)) 'Foreground API recognized by executable, home and profile'
    Check (-not [CodexDual.Native]::IsInstanceForeground($exe,$official.Home,$api.Profile)) 'Same window with wrong home does not suppress notifications'
    Check (-not [CodexDual.Native]::IsInstanceForeground($exe,$api.Home,$official.Profile)) 'Same executable with another profile does not suppress notifications'
    Check (-not [CodexDual.Native]::IsInstanceForeground((Join-Path $root 'other.exe'),$api.Home,$api.Profile)) 'Wrong executable does not suppress notifications'
    Check (-not [CodexDual.Native]::IsInstanceForeground($exe,'','')) 'Missing routing identity cannot suppress notifications'
    [void](Focus $official)
    Wait-For {[CodexDual.Native]::IsInstanceForeground($exe,$official.Home,$official.Profile)} 'other instance foreground'
    Check (-not [CodexDual.Native]::IsInstanceForeground($exe,$api.Home,$api.Profile)) 'Official foreground leaves background API notifications enabled'
    [void](Focus $api)

    foreach($field in @('Started','Path','Command')) {
        $stale=$api.Process.PSObject.Copy()
        switch($field){'Started'{$stale.Started='1'};'Path'{$stale.Path=Join-Path $root 'other.exe'};'Command'{$stale.Command+=' --unexpected'}}
        Check ((Focus $api $stale) -eq 'Fallback') ('Changed '+$field+' rejected')
    }
    $wrongHome=[pscustomobject]@{Home=$official.Home;Profile=$api.Profile;Process=$api.Process}
    $wrongProfile=[pscustomobject]@{Home=$api.Home;Profile=$official.Profile;Process=$api.Process}
    Check ((Focus $wrongHome) -eq 'Fallback') 'Wrong home rejected'
    Check ((Focus $wrongProfile) -eq 'Fallback') 'Wrong profile rejected'

    $hidden=Start-Fixture 'hidden' 'hidden'
    Wait-For {@([CodexDual.Native]::Windows($hidden.Process.Id)|Where-Object {$_.Visible}).Count -eq 0} 'fixture hidden'
    Check ((Focus $hidden) -eq 'Fallback' -and @([CodexDual.Native]::Windows($hidden.Process.Id)|Where-Object {$_.Visible}).Count -eq 0) 'Hidden window remains hidden and requests normal path'
    $multiple=Start-Fixture 'multiple' 'multiple'
    Wait-For {@([CodexDual.Native]::Windows($multiple.Process.Id)|Where-Object {$_.Visible}).Count -eq 2} 'two visible windows'
    Check ((Focus $multiple) -eq 'Fallback') 'Multiple visible main windows require selection'
    $tool=Start-Fixture 'tool' 'tool'
    Wait-For {@([CodexDual.Native]::Windows($tool.Process.Id)|Where-Object {$_.Visible}).Count -eq 1} 'tool window excluded'
    Check ((Focus $tool) -in @('Shown','Running')) 'Tool window does not block single-main-window focus'

    [void](Stop-VerifiedProcess $hidden.Process)
    Wait-For {-not (Get-Process -Id $hidden.Process.Id -ErrorAction SilentlyContinue)} 'fixture exit'
    Check ((Focus $hidden) -eq 'Fallback') 'Exited process is rejected'

    $instance=[pscustomobject]@{id=[Guid]::NewGuid().ToString('N');role='api';home=$api.Home;profile=$api.Profile}
    $script:statusCache=@{api=[pscustomobject]@{Role='api';InstanceId=$instance.id;Home=$api.Home;Profile=$api.Profile;State='Running';Process=$api.Process}}
    $script:openBusy=$false;$script:preferences=@{}
    $script:fallbacks=0;$script:messages=@();$script:rejectFallback=$true
    function Start-PanelOpen([string[]]$Roles,[string]$ThreadId='') {
        if($script:rejectFallback){throw 'Cached focus invoked Start-PanelOpen'}
        $script:fallbacks++;$script:lastFallback=$Roles[0]
    }
    function Set-UiMessage($message) {$script:messages+=,[string]$message}
    function Get-InstanceDisplayName($Instance,$Preferences) {return 'API fixture'}
    Open-PanelInstance $instance
    Check ($script:fallbacks -eq 0 -and $script:messages.Count -eq 1 -and $script:messages[0] -match 'API fixture') 'Matching cache focuses without starting background open'
    $script:rejectFallback=$false
    $script:statusCache.api.State='Unknown'
    Open-PanelInstance $instance
    Check ($script:fallbacks -eq 1 -and $script:lastFallback -eq 'api') 'Unknown cache falls back to normal open'
    $script:statusCache.Clear()
    Open-PanelInstance $instance
    Check ($script:fallbacks -eq 2) 'Missing cache falls back to normal open'
    $script:statusCache.api=[pscustomobject]@{Role='api';InstanceId=('f'*32);Home=$api.Home;Profile=$api.Profile;State='Running';Process=$api.Process}
    Open-PanelInstance $instance
    Check ($script:fallbacks -eq 3) 'Other instance cache is not used'
    $script:openBusy=$true
    Open-PanelInstance $instance
    Check ($script:fallbacks -eq 3 -and $script:messages.Count -eq 1) 'Busy entry does not reenter either route'
} finally {
    foreach($process in $started){
        try {if(Test-ExpectedProcessAlive $process){Stop-VerifiedProcess $process}} catch {Write-Warning ('Fixture cleanup failed for PID '+$process.Id)}
    }
}
Write-Output "PASSED: $script:passed fast restore checks"
