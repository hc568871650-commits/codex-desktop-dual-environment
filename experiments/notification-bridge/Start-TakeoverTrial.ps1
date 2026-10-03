$ErrorActionPreference='Stop'
. "$PSScriptRoot\Trial.Common.ps1"
$trial=Read-BridgeTrial $PSScriptRoot
$controller=Join-Path $trial.root 'Controller\CodexDualController.exe'
$configPath=Join-Path $trial.root 'Controller\instances.local.json'
$config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json
$api=@($config.instances|Where-Object {$_.role -eq 'api'})
if($api.Count -ne 1 -or $api[0].home -ne $trial.apiHome -or $api[0].profile -ne $trial.profile){throw 'The controller does not belong to this isolated trial.'}
$manifest=Get-Content -LiteralPath (Join-Path $trial.root 'Controller\install-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
$entry=@($manifest.files|Where-Object {$_.path -eq 'CodexDualController.exe'})
if($entry.Count -ne 1){throw 'Controller binary is not registered in this trial.'}
Assert-TrialBinary $controller $entry[0].sha256
& "$PSScriptRoot\Enable-BridgeTrial.ps1"|Out-Null
$info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$controller;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WorkingDirectory=Split-Path $controller -Parent
$info.Arguments='--background --config "'+$configPath+'"'
$process=[Diagnostics.Process]::Start($info);$process.Dispose()
& "$PSScriptRoot\Start-BridgeTrial.ps1"|Out-Null
