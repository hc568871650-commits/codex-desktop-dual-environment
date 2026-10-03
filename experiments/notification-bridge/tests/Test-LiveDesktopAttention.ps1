param([Parameter(Mandatory=$true)][string]$TrialDirectory,[ValidateSet('Prepare','Foreground','Background')][string]$Phase='Prepare')
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo 'src/Instances.ps1')
Add-Type -Path (Join-Path $repo 'tests/HostAutomation.cs')
. (Join-Path $PSScriptRoot '../Trial.Common.ps1')
$m=Read-BridgeTrial $TrialDirectory
$config=Read-ControllerConfig (Join-Path $m.root 'Controller/instances.local.json')
$api=@($config.instances|Where-Object {$_.role -eq 'api'})[0]
$rootProcess=Get-Content (Join-Path $m.root 'desktop-process.json') -Raw|ConvertFrom-Json
$current=Get-Process -Id $rootProcess.pid
if($current.StartTime.ToUniversalTime().ToString('o') -ne $rootProcess.startedUtc -or $current.Path -ne $m.desktopExe){throw 'Trial desktop identity changed.'}
$controller=@(Get-ProcessSnapshot|Where-Object {Test-SamePath $_.Path (Join-Path $m.root 'Controller/CodexDualController.exe')})
if($controller.Count -ne 1){throw 'Trial controller identity ambiguous.'}
$resultPath=Join-Path $m.root 'desktop-attention.json'
$session=Join-Path $api.home 'sessions/2026/10/03/rollout-attention-fixture.jsonl'
if($Phase -eq 'Prepare'){
    if(Test-Path $session){throw 'Fixture already exists.'}
    $thread=[guid]::NewGuid().ToString();[void][IO.Directory]::CreateDirectory((Split-Path $session -Parent))
    Write-AtomicText $session ((@{type='session_meta';payload=@{id=$thread;source='vscode';originator='Codex Desktop'}}|ConvertTo-Json -Compress)+"`n")
    Write-AtomicText $resultPath (@{desktopPid=$current.Id;controllerPid=$controller[0].Id;threadId=$thread;modelRequests=0;scope='synthetic completion events through actual worker, controller and isolated Desktop foreground'}|ConvertTo-Json)
    Write-Output 'Prepared metadata-only notification fixture in isolated home.';return
}
$result=Get-Content $resultPath -Raw|ConvertFrom-Json
$isForeground=[CodexDual.Native]::IsInstanceForeground($m.desktopExe,$api.home,$api.profile)
if($isForeground -ne ($Phase -eq 'Foreground')){throw ('Wrong foreground precondition: '+$Phase)}
$turn=[guid]::NewGuid().ToString()
$event=@{type='event_msg';payload=@{type='task_complete';turn_id=$turn}}|ConvertTo-Json -Compress
[IO.File]::AppendAllText($session,$event+"`n",(New-Object Text.UTF8Encoding($false)))
$settings=Get-Content (Join-Path $config.stateDirectory 'notifications/settings.local.json') -Raw|ConvertFrom-Json
$checkpoint=Join-Path $config.stateDirectory ('notifications/monitor-'+$settings.epoch+'.local.json')
$deadline=[DateTime]::UtcNow.AddSeconds(8)
do{
    $consumed=(Test-Path $checkpoint) -and ([IO.File]::ReadAllText($checkpoint)).Contains($turn)
    if($consumed){break};Start-Sleep -Milliseconds 100
}while([DateTime]::UtcNow -lt $deadline)
if(-not $consumed){throw 'Worker did not consume synthetic completion.'}
Start-Sleep -Milliseconds 1400
$cardHandle=[CodexDualTests.HostAutomation]::FindDialog($controller[0].Id,'API 环境 · 任务完成')
$cards=@();if($cardHandle){$cards+=[pscustomobject]@{Handle=$cardHandle;Title='API 环境 · 任务完成'}}
if($Phase -eq 'Foreground' -and $cards.Count -ne 0){throw 'Foreground completion incorrectly displayed.'}
if($Phase -eq 'Background' -and $cards.Count -ne 1){throw 'Background completion did not display.'}
$result|Add-Member NoteProperty $Phase (@{passed=$true;foregroundMatched=$isForeground;visibleCards=$cards.Count;turnId=$turn;utc=[DateTime]::UtcNow.ToString('o')}) -Force
Write-AtomicText $resultPath ($result|ConvertTo-Json -Depth 6)
Write-Output ('PASS actual Desktop '+$Phase+' completion behavior; cards='+$cards.Count)
if($cards.Count){$cards|Select-Object Handle,Title|ConvertTo-Json}
