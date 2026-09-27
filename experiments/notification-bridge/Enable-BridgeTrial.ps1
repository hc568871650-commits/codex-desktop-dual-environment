param([string]$TrialDirectory=$PSScriptRoot)
. "$PSScriptRoot\Trial.Common.ps1"
$m=Read-BridgeTrial $TrialDirectory
Assert-TrialBinary (Join-Path $m.root 'BridgeProxy.exe') $m.proxyHash
Assert-TrialBinary $m.realCli $m.realCliHash
$config=Get-Content -LiteralPath (Assert-PlainTrialPath (Join-Path $m.root 'bridge.config.json')) -Raw -Encoding UTF8|ConvertFrom-Json
if($config.apiHome -ne $m.apiHome -or $config.realCli -ne $m.realCli -or $config.instanceId -ne ('api-trial-'+$m.id) -or $config.pipeName -ne ('codex-api-question-trial-'+$m.id)){throw 'Bridge configuration no longer matches this trial.'}
$disabled=Join-Path $m.root 'DISABLED'
if(Test-Path -LiteralPath $disabled){Remove-Item -LiteralPath $disabled}
Write-Output 'Enabled for the next isolated trial launch. An already-disabled proxy stays disabled until restart. The daily API installation is unchanged.'
