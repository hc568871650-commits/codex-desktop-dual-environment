param([switch]$Integration)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
$script:passed=0
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"};$script:passed++;Write-Output "PASS: $Message"}
function Throws([scriptblock]$Code,$Message){$did=$false;try{& $Code | Out-Null}catch{$did=$true};Assert $did $Message}
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ([Guid]::NewGuid().ToString('N')+' space 中文')
[void][IO.Directory]::CreateDirectory($root)
$exe=Join-Path $root 'Fixture.exe'
$a=[pscustomobject]@{id=[Guid]::NewGuid().ToString('N');role='official';home="$root\OfficialHome";profile="$root\OfficialProfile";projects="$root\OfficialProjects";projectless="$root\OfficialProjectless";executable=$exe;launchMode='official'}
$b=[pscustomobject]@{id=[Guid]::NewGuid().ToString('N');role='api';home="$root\ApiHome";profile="$root\ApiProfile";projects="$root\ApiProjects";projectless="$root\ApiProjectless";executable=$exe;launchMode='official'}
$config=[pscustomobject]@{schema=1;stateDirectory="$root\state";instances=@($a,$b)}
$p=[pscustomobject]@{Id=100;ParentId=1;Path=$exe;Command='"'+$exe+'" --user-data-dir="'+$a.profile+'"';Started='1000'}
$q=[pscustomobject]@{Id=101;ParentId=1;Path=$exe;Command='"'+$exe+'" --user-data-dir "'+$b.profile+'"';Started='1001'}
$reader={param($n) if($n -eq 100){$a.home}else{$b.home}}
Assert ((Get-ProfileArgument $p.Command) -eq $a.profile) 'Quoted equals profile parsed'
Assert ((Get-ProfileArgument $q.Command) -eq $b.profile) 'Separate profile argument parsed'
Throws {Get-ProfileArgument ($p.Command+' --user-data-dir=other')} 'Duplicate profile rejected'
Assert ((Resolve-Instance $a @($p,$q) $exe $reader).Process.Id -eq 100) 'Official identified by home and profile'
Assert ((Resolve-Instance $b @($p,$q) $exe $reader).Process.Id -eq 101) 'API identified independently'
Assert ((Resolve-Instance $a @($p) $exe {param($n) throw 'Denied'}).State -eq 'Unknown') 'Unreadable home fails closed'
Assert ((Resolve-Instance $a @($p) $exe {param($n) 'C:\Unrelated'}).State -eq 'Unknown') 'Profile collision with different home blocks startup'
Assert ((Resolve-Instance $a @($p,$p) $exe $reader).State -eq 'Unknown') 'Duplicate matching processes rejected'
Assert ((Resolve-Instance $a @($p) 'C:\Other\Fixture.exe' $reader).State -eq 'Stopped') 'Same name different path excluded'
$reuse=$p.PSObject.Copy();$reuse.Started='2000'
Assert (-not (Test-ProcessIdentity $p $reuse)) 'PID reuse rejected'
Assert (-not (Test-ProcessIdentity $p $null)) 'Exited process rejected'
$child=[pscustomobject]@{Id=102;ParentId=100;Path=$exe;Command='"'+$exe+'" --type=renderer';Started='1002'}
$server=[pscustomobject]@{Id=103;ParentId=100;Path='C:\External\node.exe';Command='node server.js';Started='1002'}
$oldchild=$child.PSObject.Copy();$oldchild.Id=104;$oldchild.Started='900'
$owned=@(Get-OwnedDesktopChildren $p @($p,$child,$server,$oldchild))
Assert ($owned.Count -eq 2 -and 102 -in $owned.Id) 'Only verified desktop descendants selected'
Assert (103 -notin $owned.Id -and 104 -notin $owned.Id) 'External task server and reused parent excluded'
Throws {Stop-InstanceForced $a $p} 'Force exit requires explicit confirmation'
$confPath=Join-Path $root 'instances.local.json';Write-AtomicText $confPath ($config|ConvertTo-Json -Depth 5)
Assert ((Read-ControllerConfig $confPath).instances.Count -eq 2) 'Configuration validates independent directories'
$b.home=$a.home;Write-AtomicText $confPath ($config|ConvertTo-Json -Depth 5)
Throws {Read-ControllerConfig $confPath} 'Overlapping homes refused'
$b.home="$root\ApiHome";Write-AtomicText $confPath ($config|ConvertTo-Json -Depth 5)
if($Integration){
    Add-Type -Path "$PSScriptRoot\Fixture.cs" -ReferencedAssemblies System.Windows.Forms,System.Drawing -OutputAssembly $exe -OutputType WindowsApplication
    Assert ([CodexDual.Native]::IsGuiImage($exe)) 'GUI image accepted as desktop candidate'
    Assert (-not [CodexDual.Native]::IsGuiImage("$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")) 'Console app-server style image excluded from desktop candidates'
    foreach($i in @($a,$b)){foreach($key in @('home','profile','projects','projectless')){[void][IO.Directory]::CreateDirectory($i.$key)}}
    foreach($i in @($a,$b)){Write-AtomicText (Join-Path $i.home 'config.toml') ("[desktop]`r`nprojectlessWorkspaceRoot = "+(ConvertTo-TomlString $i.projectless))}
    $launched=@()
    try{
        $pa=Start-OrFindInstance $config $a;$launched+=$pa
        $pb=Start-OrFindInstance $config $b;$launched+=$pb
        Assert ($pa.Id -ne $pb.Id) 'Two separate real GUI fixture processes running'
        $again=Start-OrFindInstance $config $a
        Assert ($again.Id -eq $pa.Id) 'Repeated start reuses existing process'
        $reloaded=Read-ControllerConfig $confPath
        Assert ((Get-InstanceStatus $reloaded $reloaded.instances[1]).Process.Id -eq $pb.Id) 'Restarted controller recognizes running instance'
        Start-Sleep -Milliseconds 800
        $wins=@(Get-InstanceWindows $a $pa)
        Assert ($wins.Count -eq 2) 'Enumerates multiple windows including minimized'
        Assert (@($wins | Where-Object {$_.Title -like 'Internal overlay*'}).Count -eq 0) 'Hidden topmost tool window excluded from restore and close targets'
        [void](Show-InstanceWindow $a $pa $wins[0].Handle)
        Assert (@(Get-InstanceWindows $b $pb).Count -eq 2) 'Locating official leaves API windows present'
        Throws {Show-InstanceWindow $a $pa 1} 'Invalid window handle rejected'
        $fake=$pa.PSObject.Copy();$fake.Started='1'
        Throws {Assert-CurrentIdentity $a $fake} 'Live stale PID record rejected'
        Throws {Stop-VerifiedProcess $fake} 'Stale live identity cannot be killed'
        Throws {Assert-NotCurrentHost ([pscustomobject]@{Id=$PID})} 'Current task process protected from exit'
        $before=Get-ProcessSnapshot
        Request-InstanceClose $b $pb;Start-Sleep -Milliseconds 700
        Assert ((Get-InstanceStatus $config $b).State -eq 'Stopped') 'Normal exit closes API fixture'
        Assert ((Get-InstanceStatus $config $a).State -eq 'Running') 'API exit preserves official fixture'
        $pb=Start-OrFindInstance $config $b;$launched+=$pb
        [void](Stop-InstanceForced $a $pa -UserConfirmed);Start-Sleep -Milliseconds 500
        Assert ((Get-InstanceStatus $config $a).State -eq 'Stopped') 'Confirmed forced exit closes official fixture'
        Assert ((Get-InstanceStatus $config $b).State -eq 'Running') 'Official exit preserves API fixture'
        Assert (@(Get-ExitResiduals $before @($pa)).Count -eq 0) 'Exited identity absent from residual report'
        [IO.File]::WriteAllText((Join-Path $a.profile 'stubborn.fixture'),'')
        [IO.File]::WriteAllText((Join-Path $a.profile 'hidden.fixture'),'')
        $pa=Start-OrFindInstance $config $a;$launched+=$pa;Start-Sleep -Milliseconds 500
        $hidden=@(Get-InstanceWindows $a $pa)
        Assert ($hidden.Count -eq 2 -and @($hidden | Where-Object {$_.Visible}).Count -eq 0) 'Hidden windows still discoverable'
        Throws {Show-InstanceWindow $a $pa $hidden[0].Handle} 'Hidden window cannot be forcibly shown outside native app activation'
        Request-InstanceClose $a $pa;Start-Sleep -Milliseconds 400
        Assert ((Get-InstanceStatus $config $a).State -eq 'Running') 'Close-to-tray correctly reported as still running'
        [void](Stop-InstanceForced $a $pa -UserConfirmed);Start-Sleep -Milliseconds 300
        Assert ((Get-InstanceStatus $config $a).State -eq 'Stopped') 'Confirmed force handles background residency'
        $external=Join-Path $root 'external-launch.ps1'
        $instancesFile=[IO.Path]::GetFullPath("$PSScriptRoot\..\src\Instances.ps1").Replace("'","''")
        $scriptText=". '$instancesFile'`r`n"+
            "`$i=New-CodexStartInfo -Executable '"+$exe.Replace("'","''")+"' -OfficialHome '"+$a.home.Replace("'","''")+"'`r`n"+
            "`$i.Arguments='--user-data-dir="""+$a.profile.Replace("'","''")+"""'`r`n"+
            "`$i.WorkingDirectory='"+$a.projects.Replace("'","''")+"'`r`n[void][CodexDual.Native]::StartDetached(`$i)`r`n"
        [IO.File]::WriteAllText($external,$scriptText,(New-Object Text.UTF8Encoding($true)))
        $a.launchMode='external';$a | Add-Member NoteProperty externalLauncher $external
        $pa=Start-OrFindInstance $config $a;$launched+=$pa
        Assert ((Get-InstanceStatus $config $a).State -eq 'Running') 'Existing external launcher works with sanitized child environment'
        [void](Stop-InstanceForced $a $pa -UserConfirmed);Start-Sleep -Milliseconds 200
        $a.projects="$root\Missing"
        Throws {Start-OrFindInstance $config $a} 'Missing directory blocks launch'
    }finally{
        foreach($launchedProcess in $launched){
            # Cleanup restricted to this test's executable and captured process identities.
            if(Test-SamePath $launchedProcess.Path $exe){try{Stop-VerifiedProcess $launchedProcess}catch{Write-Warning 'Fixture cleanup identity changed; left untouched.'}}
        }
    }
}
Write-Output "PASSED: $script:passed assertions. Integration=$Integration"
