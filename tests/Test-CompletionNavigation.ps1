$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
. "$PSScriptRoot\..\src\CompletionNavigation.ps1"
$script:passed=0
function Check($Value,[string]$Message){if(-not $Value){throw ('FAIL: '+$Message)};$script:passed++;Write-Output ('PASS: '+$Message)}
function Throws([scriptblock]$Code,[string]$Message){$failed=$false;try{& $Code|Out-Null}catch{$failed=$true};Check $failed $Message}

$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('completion-navigation-'+[Guid]::NewGuid().ToString('N'))
$fixtureHome=Join-Path $root 'home';$profile=Join-Path $root 'profile';$projects=Join-Path $root 'projects'
foreach($path in @($fixtureHome,$profile,$projects)){[void][IO.Directory]::CreateDirectory($path)}
$instance=[pscustomobject]@{id=('a'*32);home=$fixtureHome;profile=$profile;projects=$projects}
$threadId=[Guid]::NewGuid().ToString()
Check (Test-TaskIdentifier $threadId) 'Canonical UUID accepted'
foreach($bad in @('', 'new', '../../other', ($threadId+'?hostId=other'), (' '+$threadId), ('{'+$threadId+'}'))){Check (-not (Test-TaskIdentifier $bad)) ('Invalid task ID rejected: '+$bad)}
Check ((Get-CompletionTaskTitle $instance 'invalid') -eq '任务已完成') 'Invalid ID does not read title'
Check ((Get-CompletionTaskTitle $instance $threadId) -eq '任务已完成') 'Missing index uses fallback'

$index=Join-Path $fixtureHome 'session_index.jsonl'
$utf8=New-Object Text.UTF8Encoding($false)
$oldTitle='old title'
$lines=@('{malformed',(@{id=$threadId;thread_name=$oldTitle;updated_at='old'}|ConvertTo-Json -Compress),
    (@{id=[Guid]::NewGuid().ToString();thread_name='other'}|ConvertTo-Json -Compress),
    (@{id=$threadId;thread_name=("`r`nVisible"+[char]0x200b+" title`t");updated_at='new'}|ConvertTo-Json -Compress))
[IO.File]::WriteAllText($index,($lines -join "`n")+"`n",$utf8)
Check ((Get-CompletionTaskTitle $instance $threadId) -eq 'Visible  title') 'Newest matching index title sanitized; invalid JSON skipped'
$long=('A'*130)
[IO.File]::AppendAllText($index,(@{id=$threadId;thread_name=$long}|ConvertTo-Json -Compress)+"`n",$utf8)
$title=Get-CompletionTaskTitle $instance $threadId
Check ($title.Length -eq 100 -and $title.StartsWith('A'*99)) 'Notification title capped at 100 characters'
[IO.File]::WriteAllText($index,(@{id=$threadId;thread_name='outside-bound'}|ConvertTo-Json -Compress)+"`n"+('x'*270000)+"`n",$utf8)
Check ((Get-CompletionTaskTitle $instance $threadId) -eq '任务已完成') 'Index search bounded to last 256 KiB'
[IO.File]::WriteAllText($index,"{malformed`n",$utf8)
Check ((Get-CompletionTaskTitle $instance $threadId) -eq '任务已完成') 'Invalid index content uses fallback'
$locked=New-Object IO.FileStream($index,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{Check ((Get-CompletionTaskTitle $instance $threadId) -eq '任务已完成') 'Unavailable index uses fallback'}finally{$locked.Dispose()}

# A temporary PowerShell fixture exposes real process environment to Native.ElectronUserData.
$fixtureExe="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$script:launched=New-Object 'Collections.Generic.List[Diagnostics.Process]'
function Start-EnvironmentFixture([string]$ElectronPath) {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$fixtureExe;$info.Arguments='-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.EnvironmentVariables.Remove('CODEX_ELECTRON_USER_DATA_PATH')
    if($null -ne $ElectronPath){$info.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH']=$ElectronPath}
    $p=[Diagnostics.Process]::Start($info);$script:launched.Add($p);return $p
}
try{
    $matching=Start-EnvironmentFixture $profile
    $missing=Start-EnvironmentFixture $null
    $other=Join-Path $root 'different-profile';[void][IO.Directory]::CreateDirectory($other)
    $different=Start-EnvironmentFixture $other
    Check (Test-SamePath ([CodexDual.Native]::ElectronUserData($matching.Id)) $profile) 'Native reads actual matching Electron directory'
    Check (-not [CodexDual.Native]::ElectronUserData($missing.Id)) 'Native reports missing Electron directory'
    Check (Test-SamePath ([CodexDual.Native]::ElectronUserData($different.Id)) $other) 'Native reads different Electron directory'

    # Use real environment reads, but intercept executable discovery and redirect any launch to a missing fixture.
    $realStartInfo=(Get-Command New-CodexStartInfo).ScriptBlock
    $script:captured=$null
    $script:storePath=$fixtureExe
    function Find-CodexExecutable {param([string]$ExplicitPath) if(-not $script:storePath){throw 'No Store installation'};return $script:storePath}
    function Assert-CurrentIdentity {param($Instance,$Process) if(-not (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue)){throw 'Fixture exited'}}
    function Invoke-InstanceLocked {param($Instance,[scriptblock]$Action) & $Action}
    function New-CodexStartInfo {
        param([string]$Executable,[string]$OfficialHome,[string]$ApiRoot,[switch]$Api)
        $script:captured=& $realStartInfo -Executable $Executable -OfficialHome $OfficialHome
        $script:captured.FileName=Join-Path $root 'missing-fixture.exe'
        return $script:captured
    }
    $process=[pscustomobject]@{Id=$matching.Id;Path=$fixtureExe}
    Throws {Request-InstanceTask $instance $process 'invalid'} 'Invalid UUID blocks before launch'
    Check ($null -eq $script:captured) 'Invalid UUID did not construct a launch'
    $script:storePath=$null
    Check ((Request-InstanceTask $instance $process $threadId) -eq 'Unsupported') 'Missing Store installation does not launch'
    $script:storePath=Join-Path $root 'old-version.exe'
    Check ((Request-InstanceTask $instance $process $threadId) -eq 'Unsupported') 'Different Store executable does not launch'
    Check ($null -eq $script:captured) 'Store discovery failure did not construct a launch'
    $script:storePath=$fixtureExe
    $process.Id=$missing.Id
    Check ((Request-InstanceTask $instance $process $threadId) -eq 'Unsupported') 'Missing Electron directory fails closed for profiled instance'
    $process.Id=$different.Id
    Check ((Request-InstanceTask $instance $process $threadId) -eq 'Unsupported') 'Different Electron directory fails closed'
    Check ($null -eq $script:captured) 'Mismatch did not construct a launch'
    $process.Id=$matching.Id
    Throws {Request-InstanceTask $instance $process $threadId} 'Matched directory reaches deliberately invalid executable'
    Check ($script:captured.EnvironmentVariables['CODEX_HOME'] -eq $fixtureHome) 'Target CODEX_HOME set from instance'
    Check (Test-SamePath $script:captured.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] $profile) 'Target Electron directory copied from verified process'
    Check ($script:captured.Arguments.Contains('--user-data-dir="'+$profile+'"') -and $script:captured.Arguments.Contains('"codex://threads/'+$threadId+'"')) 'Target profile and validated task URI passed as arguments'
    $argv=[CodexDual.Native]::Arguments(('"'+$fixtureExe+'" '+$script:captured.Arguments))
    Check ($argv.Count -eq 3 -and $argv[1] -eq ('--user-data-dir='+$profile) -and $argv[2] -eq ('codex://threads/'+$threadId)) 'Windows argument parser receives exact target profile and URI'
    $instance.profile=''
    $process.Id=$matching.Id
    Check ((Request-InstanceTask $instance $process $threadId) -eq 'Unsupported') 'Default instance rejects explicit Electron directory'
    $process.Id=$missing.Id;$script:captured=$null
    Throws {Request-InstanceTask $instance $process $threadId} 'Default directory reaches deliberately invalid executable'
    Check ($script:captured.EnvironmentVariables['CODEX_HOME'] -eq $fixtureHome -and -not $script:captured.EnvironmentVariables.ContainsKey('CODEX_ELECTRON_USER_DATA_PATH')) 'Default launch keeps home but omits Electron override'
    Check ($script:captured.Arguments -eq ('"codex://threads/'+$threadId+'"')) 'Default launch passes only validated task URI'
    $argv=[CodexDual.Native]::Arguments(('"'+$fixtureExe+'" '+$script:captured.Arguments))
    Check ($argv.Count -eq 2 -and $argv[1] -eq ('codex://threads/'+$threadId)) 'Default Windows arguments contain only the task URI'
}finally{
    foreach($fixture in $script:launched){
        try{if(-not $fixture.HasExited){$fixture.Kill();[void]$fixture.WaitForExit(3000)}}finally{$fixture.Dispose()}
    }
}
Write-Output "PASSED: $script:passed completion navigation checks. Output: $root"
