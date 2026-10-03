param(
    [Parameter(Mandatory=$true)][string]$Destination,
    [Parameter(Mandatory=$true)][string]$RealCli,
    [Parameter(Mandatory=$true)][string]$DesktopExecutable
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
& "$PSScriptRoot\New-BridgeTrial.ps1" -Destination $Destination -RealCli $RealCli -DesktopExecutable $DesktopExecutable -TakeoverQuestions|Out-Null
. "$repo\src\Instances.ps1"
$trial=Get-FullDirectory $Destination;$target=Join-Path $trial 'Controller'
foreach($folder in @('OfficialHome','OfficialProfile','OfficialProjects','OfficialProjectless','Projectless','ControllerState','Shortcuts')){[void][IO.Directory]::CreateDirectory((Join-Path $trial $folder))}
$apiId=[guid]::NewGuid().ToString('N')
$config=@{schema=1;stateDirectory=(Join-Path $trial 'ControllerState');instances=@(
    @{id=[guid]::NewGuid().ToString('N');role='official';home=(Join-Path $trial 'OfficialHome');profile=(Join-Path $trial 'OfficialProfile');projects=(Join-Path $trial 'OfficialProjects');projectless=(Join-Path $trial 'OfficialProjectless');launchMode='official';executable=$DesktopExecutable},
    @{id=$apiId;role='api';home=(Join-Path $trial 'CodexHome');profile=(Join-Path $trial 'DesktopProfile');projects=(Join-Path $trial 'Projects');projectless=(Join-Path $trial 'Projectless');launchMode='external';externalLauncher=(Join-Path $trial 'Start-BridgeTrial.ps1');executable=$DesktopExecutable}
)}
$path=Join-Path $trial 'controller-config.json';Write-AtomicText $path ($config|ConvertTo-Json -Depth 8)
& "$repo\scripts\Deploy-Controller.ps1" -ConfigPath $path -Destination $target -DisplayName 'API question takeover trial' -ShortcutDirectory (Join-Path $trial 'Shortcuts')|Out-Null
$installed=Read-ControllerConfig (Join-Path $target 'instances.local.json')
# Independent acceptance must not collide with the daily per-user controller.
# Namespace only this disposable copy; the production singleton stays unchanged.
$trialController=Join-Path $target 'src\Controller.ps1'
$controllerText=[IO.File]::ReadAllText($trialController)
$mutexAnchor="'Local\CodexDual.Controller.'"
if(-not $controllerText.Contains($mutexAnchor)){throw 'Trial controller singleton anchor changed.'}
[IO.File]::WriteAllText($trialController,($controllerText.Replace($mutexAnchor,("'Local\CodexDual.Trial."+$apiId+".'"))),(New-Object Text.UTF8Encoding($true)))
$installManifestPath=Join-Path $target 'install-manifest.json'
$installManifest=Get-Content $installManifestPath -Raw -Encoding UTF8|ConvertFrom-Json
foreach($entry in $installManifest.files){if($entry.path -eq 'src\Controller.ps1'){$entry.sha256=(Get-FileHash $trialController).Hash}}
Write-AtomicText $installManifestPath ($installManifest|ConvertTo-Json -Depth 8)
[void](Set-WindowBehavior $installed 'focus' $false 'passive' $true)
Write-AtomicText (Join-Path $installed.stateDirectory 'question-bridge.local.json') (@{schema=1;directory=$trial;instanceId=$apiId}|ConvertTo-Json)
Copy-Item -LiteralPath "$PSScriptRoot\Start-TakeoverTrial.ps1" -Destination $trial
$commands=@{
    'Open-ExperimentalController.cmd'='start "" "%~dp0Controller\CodexDualController.exe" --config "%~dp0Controller\instances.local.json"'
    'Open-Questions.cmd'='start "" "%~dp0Controller\CodexDualController.exe" --config "%~dp0Controller\instances.local.json"'
    'Start-TakeoverTrial.cmd'='powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Start-TakeoverTrial.ps1"'
    'Preview-PassiveQuestion.cmd'='powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Controller\scripts\Preview-Questions.ps1" -FocusMode passive -DelaySeconds 3'
    'Preview-FocusedQuestion.cmd'='powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Controller\scripts\Preview-Questions.ps1" -FocusMode focus -DelaySeconds 3'
}
foreach($entry in $commands.GetEnumerator()){[IO.File]::WriteAllText((Join-Path $trial $entry.Key),('@echo off'+"`r`n"+$entry.Value+"`r`n"),[Text.Encoding]::ASCII)}
Write-Output $trial
