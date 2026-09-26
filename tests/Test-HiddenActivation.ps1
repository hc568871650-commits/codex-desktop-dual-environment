$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"

$script:passed=0
function Check($condition,[string]$message) {
    if(-not $condition){throw "FAIL: $message"}
    $script:passed++;Write-Output "PASS: $message"
}
function Wait-For([scriptblock]$condition,[string]$message) {
    for($attempt=0;$attempt -lt 60;$attempt++) {
        if(& $condition){return}
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out: $message"
}
function Fixture-Key([string]$profile) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($profile.ToLowerInvariant()))).Replace('-','')}
    finally{$sha.Dispose()}
}
function Secondary-Count([string]$profile) {
    $path=Join-Path $profile 'secondary.log'
    if(-not (Test-Path -LiteralPath $path)){return 0}
    return @([IO.File]::ReadAllLines($path)).Count
}

$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('hidden-activation-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$exe=Join-Path $root 'HiddenActivationFixture.exe'
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;
class HiddenActivationFixture {
 static string Key(string path) {
  using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(path.ToLowerInvariant()))).Replace("-","");
 }
 [STAThread] static void Main(string[] args) {
  string profile="";
  foreach(string arg in args)if(arg.StartsWith("--user-data-dir="))profile=arg.Substring(16);
  if(profile.Length==0)return;
  string name="Local\\CodexDual.HiddenFixture."+Key(profile);
  bool created;
  using(var mutex=new Mutex(false,name, out created)) {
   if(!created) {
    File.AppendAllText(Path.Combine(profile,"secondary.log"),"request\n");
    using(var signal=EventWaitHandle.OpenExisting(name+".wake"))signal.Set();
    return;
   }
   using(var wake=new EventWaitHandle(false,EventResetMode.AutoReset,name+".wake"))
   using(var hide=new EventWaitHandle(false,EventResetMode.AutoReset,name+".hide")) {
    var form=new Form{Text="Hidden activation primary",Width=360,Height=180};
    form.Shown+=(s,e)=>form.BeginInvoke((Action)(()=>form.Hide()));
    var wakeWait=ThreadPool.RegisterWaitForSingleObject(wake,(state,timedOut)=>{
     try {form.BeginInvoke((Action)(()=>{form.Show();form.Activate();}));}catch(InvalidOperationException){}
    },null,Timeout.Infinite,false);
    var hideWait=ThreadPool.RegisterWaitForSingleObject(hide,(state,timedOut)=>{
     try {form.BeginInvoke((Action)(()=>form.Hide()));}catch(InvalidOperationException){}
    },null,Timeout.Infinite,false);
    try{Application.Run(form);}finally{wakeWait.Unregister(null);hideWait.Unregister(null);}
   }
  }
 }
}
'@ -ReferencedAssemblies System.Windows.Forms,System.Drawing -OutputAssembly $exe -OutputType WindowsApplication

$fixtureHome=Join-Path $root 'home';$fixtureProfile=Join-Path $root 'profile';$fixtureProjects=Join-Path $root 'projects'
foreach($directory in @($fixtureHome,$fixtureProfile,$fixtureProjects)){[void][IO.Directory]::CreateDirectory($directory)}
$launcherMarker=Join-Path $root 'launcher-called.marker'
$launcher=Join-Path $root 'external-launcher.ps1'
Write-AtomicText $launcher ('[IO.File]::WriteAllText("'+$launcherMarker+'","unexpected")' + "`r`nthrow 'External launcher must not run during restore'")
$instance=[pscustomobject]@{id=[Guid]::NewGuid().ToString('N');role='api';home=$fixtureHome;profile=$fixtureProfile;projects=$fixtureProjects;executable=$exe;externalLauncher=$launcher;launchMode='external'}
$originalFind=(Get-Command Find-CodexExecutable).ScriptBlock
function Find-CodexExecutable([string]$ExplicitPath){return $exe}
$primary=$null
try {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$exe;$info.UseShellExecute=$false;$info.WorkingDirectory=$root
    $info.Arguments='--user-data-dir="'+$fixtureProfile+'"'
    $info.EnvironmentVariables['CODEX_HOME']=$fixtureHome
    $primaryId=[CodexDual.Native]::StartDetached($info)
    Wait-For {@([CodexDual.Native]::Windows($primaryId)).Count -eq 1} 'primary window created'
    Wait-For {@([CodexDual.Native]::Windows($primaryId)|Where-Object {$_.Visible}).Count -eq 0} 'primary window hidden'
    $primary=@(Get-ProcessSnapshotById $primaryId)[0]
    Check ([CodexDual.Native]::IsKnownProcess($primary.Id,[long]$primary.Started,$primary.Path,$primary.Command,$fixtureHome,$fixtureProfile)) 'Hidden primary identity is independently verified'

    Check (Request-NativeInstanceActivation $instance $primary -QuickIdentity) 'Native secondary activation accepted'
    Wait-For {@([CodexDual.Native]::Windows($primaryId)|Where-Object {$_.Visible}).Count -eq 1} 'primary native wake'
    Check ((Secondary-Count $fixtureProfile) -eq 1 -and (Test-ExpectedProcessAlive $primary) -and -not (Test-Path -LiteralPath $launcherMarker)) 'Hidden primary restores with same PID through secondary, without external launcher'

    $count=Secondary-Count $fixtureProfile
    Check (Request-NativeInstanceActivation $instance $primary -QuickIdentity) 'Visible primary activation accepted'
    Check ((Secondary-Count $fixtureProfile) -eq $count) 'Visible primary does not launch secondary'

    $wrongHome=$instance.PSObject.Copy();$wrongHome.home=Join-Path $root 'wrong-home'
    $wrongStarted=$primary.PSObject.Copy();$wrongStarted.Started='1'
    $homeRejected=$false;$startedRejected=$false
    try{Request-NativeInstanceActivation $wrongHome $primary -QuickIdentity|Out-Null}catch{$homeRejected=$true}
    try{Request-NativeInstanceActivation $instance $wrongStarted -QuickIdentity|Out-Null}catch{$startedRejected=$true}
    Check ($homeRejected -and $startedRejected -and (Secondary-Count $fixtureProfile) -eq $count) 'Quick identity refuses wrong home and stale start without secondary'

    $name='Local\CodexDual.HiddenFixture.'+(Fixture-Key $fixtureProfile)+'.hide'
    $hide=[Threading.EventWaitHandle]::OpenExisting($name)
    try{[void]$hide.Set()}finally{$hide.Dispose()}
    Wait-For {@([CodexDual.Native]::Windows($primaryId)|Where-Object {$_.Visible}).Count -eq 0} 'primary hidden again'

    $cached=[pscustomobject]@{Role='api';State='Running';InstanceId=$instance.id;Home=$fixtureHome;Profile=$fixtureProfile;ConfiguredExecutable=$exe;Process=$primary}
    $script:workerConfig=[pscustomobject]@{instances=@($instance)}
    function Read-ControllerConfig([string]$Path){return $script:workerConfig}
    function Start-OrFindInstance($Config,$Instance){throw 'Worker performed full process discovery'}
    $result=@(. "$PSScriptRoot\..\src\ControllerWork.ps1" $PSScriptRoot 'fixture-config' 'open' @('api') '' @{api=$cached})
    Check ($result.Count -eq 1 -and -not $result[0].Error -and $result[0].QuickIdentity -eq $true -and $result[0].Process.Id -eq $primary.Id) 'Worker reuses current cached identity without full discovery'
    Check (@($result[0].Windows|Where-Object {$_.Visible}).Count -eq 1 -and (Secondary-Count $fixtureProfile) -eq ($count+1) -and -not (Test-Path -LiteralPath $launcherMarker)) 'Worker wakes hidden primary using native secondary only'
} finally {
    Set-Item Function:Find-CodexExecutable $originalFind
    if($primary){try{if(Test-ExpectedProcessAlive $primary){Stop-VerifiedProcess $primary}}catch{Write-Warning ('Fixture cleanup failed for PID '+$primary.Id)}}
}
Write-Output "PASSED: $script:passed hidden activation checks"
