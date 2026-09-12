param([switch]$RunIsolatedDesktop,[switch]$CleanupFixtures)
$ErrorActionPreference='Stop'
if(-not $RunIsolatedDesktop){throw '显式传入 -RunIsolatedDesktop 才会启动两个全新、无真实凭据的 Codex 测试实例。'}
. "$PSScriptRoot\..\src\Instances.ps1"
$exe=Find-CodexExecutable ''
$original=@(Get-ProcessSnapshot | Where-Object {(Test-SamePath $_.Path $exe) -and $_.Command -notmatch '--type='})
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('desktop-'+[Guid]::NewGuid().ToString('N'))
$official="$root\Official";$api="$root\API"
foreach($p in @($official,"$root\OfficialProfile","$root\OfficialProjects","$root\OfficialProjectless")){[void][IO.Directory]::CreateDirectory($p)}
Write-AtomicText "$official\config.toml" ("forced_login_method = `"api`"`r`ncli_auth_credentials_store = `"file`"`r`n[desktop]`r`nprojectlessWorkspaceRoot = "+(ConvertTo-TomlString "$root\OfficialProjectless"))
$key=ConvertTo-SecureString 'isolated-fixture-no-real-credential' -AsPlainText -Force
try{[void](Save-ApiEnvironment $api $official 'http://127.0.0.1:9/v1' 'fixture-model' $key)}finally{$key.Dispose()}
$a=[pscustomobject]@{id=[Guid]::NewGuid().ToString('N');role='official';home=$official;profile="$root\OfficialProfile";projects="$root\OfficialProjects";projectless="$root\OfficialProjectless";executable='';launchMode='official'}
$b=[pscustomobject]@{id=[Guid]::NewGuid().ToString('N');role='api';home="$api\CodexHome";profile="$api\DesktopProfile";projects="$api\Projects";projectless="$api\Projectless";executable='';launchMode='managed-api';apiRoot=$api}
$config=[pscustomobject]@{schema=1;stateDirectory="$root\state";instances=@($a,$b)}
$confPath="$root\instances.local.json";Write-AtomicText $confPath ($config|ConvertTo-Json -Depth 5)
$report=[ordered]@{version=(Get-Item -LiteralPath $exe).VersionInfo.FileVersion;configPath=$confPath;apiRequestsSent=$false;tasksStarted=$false;results=@();remaining=@()}
$started=@()
try{
foreach($i in @($a,$b)){
    $p=Start-OrFindInstance $config $i
    $started+=@{instance=$i;process=$p}
    Start-Sleep -Seconds 3
    $windows=@(Get-InstanceWindows $i $p)
    $repeat=Start-OrFindInstance $config $i
    $showResult=$false
    if($windows.Count){$showResult=Show-InstanceWindow $i $p $windows[0].Handle;Start-Sleep -Milliseconds 300}
    $report.results+=@{role=$i.role;pid=$p.Id;windowCount=$windows.Count;repeatedStartSamePid=($repeat.Id -eq $p.Id);homeConfirmed=$true;restoreRequested=$showResult;foregroundMatches=if($windows.Count){[CodexDual.Native]::Foreground() -eq $windows[0].Handle}else{$false}}
}
$report.simultaneous=(@(Get-InstanceStatus $config $a).State -eq 'Running' -and @(Get-InstanceStatus $config $b).State -eq 'Running')
$reloaded=Read-ControllerConfig $confPath
$report.rediscovered=(@(Get-InstanceStatus $reloaded $a).State -eq 'Running' -and @(Get-InstanceStatus $reloaded $b).State -eq 'Running')
}finally{
# Fresh profiles, no task prompts sent: no active development task can be in these test instances.
foreach($entry in $started){
    $i=$entry.instance
    $status=Get-InstanceStatus $config $i
    if($status.State -eq 'Running'){
        if(-not (Test-ProcessIdentity $entry.process $status.Process)){throw '测试进程身份变化，保留该进程供检查。'}
        Request-InstanceClose $i $status.Process
        Start-Sleep -Seconds 2
        $after=Get-InstanceStatus $config $i
        if($after.State -eq 'Running'){
            if($CleanupFixtures){[void](Stop-InstanceForced $i $after.Process -UserConfirmed);Start-Sleep -Milliseconds 500;$after=Get-InstanceStatus $config $i}
            if($after.State -eq 'Running'){$report.remaining+=@{role=$i.role;pid=$after.Process.Id;started=$after.Process.Started}}
        }
    }
}
$snapshot=Get-ProcessSnapshot
$report.originalInstancesUnchanged=@($original | Where-Object {$old=$_;@($snapshot | Where-Object {Test-ProcessIdentity $old $_}).Count -ne 1}).Count -eq 0
Write-AtomicText "$root\result.json" ($report|ConvertTo-Json -Depth 8)
$report|ConvertTo-Json -Depth 8
}
if(-not $report.simultaneous -or -not $report.rediscovered -or -not $report.originalInstancesUnchanged){throw '真实桌面回归未满足同时运行、重新识别或原实例保留条件。'}
if(@($report.results|Where-Object {-not $_.repeatedStartSamePid -or $_.windowCount -lt 1}).Count){throw '真实桌面去重或主窗口检查未通过。'}
if($CleanupFixtures -and $report.remaining.Count){throw '仍有本次测试实例未清理，详见报告。'}
