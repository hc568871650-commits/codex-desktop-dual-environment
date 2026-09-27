$ErrorActionPreference='Stop'
$experiment=Split-Path $PSScriptRoot -Parent
. (Join-Path $experiment 'Trial.Common.ps1')
$repo=[IO.Path]::GetFullPath((Join-Path $experiment '..\..'))
$output=Join-Path $repo ('test-results\bridge-recovery-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($output)
$fake=Join-Path $output 'Fake.exe'
& "$PSScriptRoot\Build-FakeAppServer.ps1" -Destination $fake | Out-Null
$trial=Join-Path $output 'Trial Space 中文'
& "$experiment\New-BridgeTrial.ps1" -Destination $trial -RealCli $fake -DesktopExecutable $fake | Out-Null
$passed=0
function Check($condition,[string]$name){if(-not $condition){throw ('FAIL: '+$name)};$script:passed++;Write-Output ('PASS: '+$name)}
$m=Read-BridgeTrial $trial
Check (Test-Path -LiteralPath (Join-Path $trial 'DISABLED')) 'New trial starts disabled'
$before=Get-FileHash -LiteralPath (Join-Path $trial 'bridge.config.json')
$env:BRIDGE_TRIAL_API_KEY='fixture-only-not-a-real-key'
$psi=New-TrialDesktopStartInfo $m
Check (-not $psi.EnvironmentVariables.ContainsKey('CODEX_CLI_PATH')) 'Disabled launch bypasses proxy'
Check (-not $psi.EnvironmentVariables.ContainsKey('BRIDGE_TRIAL_API_KEY')) 'Trial does not inherit API-key environment variables'
Check ($psi.EnvironmentVariables['CODEX_HOME'] -eq $m.apiHome -and $psi.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] -eq $m.profile) 'Trial home and profile are explicitly isolated'
& "$trial\Enable-BridgeTrial.ps1" | Out-Null
$psi=New-TrialDesktopStartInfo $m
Check ($psi.EnvironmentVariables['CODEX_CLI_PATH'] -eq (Join-Path $trial 'BridgeProxy.exe')) 'Enabled launch injects only bundled proxy'
$fallback=New-TrialDesktopStartInfo $m -WithoutBridge
Check (-not $fallback.EnvironmentVariables.ContainsKey('CODEX_CLI_PATH')) 'Explicit fallback bypasses enabled proxy'
$preserve=Join-Path $m.apiHome 'preserved-test-data.txt';[IO.File]::WriteAllText($preserve,'preserve')
$dataHash=(Get-FileHash -LiteralPath $preserve).Hash
& "$trial\Rollback-ApiBridge.ps1" | Out-Null
& "$trial\Rollback-ApiBridge.ps1" | Out-Null
Check ((Test-Path -LiteralPath (Join-Path $trial 'DISABLED')) -and (Get-FileHash -LiteralPath $preserve).Hash -eq $dataHash) 'Rollback is repeatable and preserves trial data'
Check ((Get-FileHash -LiteralPath (Join-Path $trial 'bridge.config.json')).Hash -eq $before.Hash) 'Rollback does not rewrite protocol configuration'
$after=New-TrialDesktopStartInfo $m
Check (-not $after.EnvironmentVariables.ContainsKey('CODEX_CLI_PATH')) 'Subsequent launch bypasses proxy after rollback'
$record=Get-Content (Join-Path $trial 'rollback-result.json') -Raw -Encoding UTF8|ConvertFrom-Json
Check ($record.processesTerminated -eq 0 -and -not $record.originalInstallationModified) 'Rollback records its non-destructive scope'
$manifestPath=Join-Path $trial 'trial.json';$original=[IO.File]::ReadAllText($manifestPath)
try{
    $m.apiHome=Join-Path $output 'NotTheTrial';Write-TrialJson $manifestPath $m
    $rejected=$false;try{& "$trial\Rollback-ApiBridge.ps1"|Out-Null}catch{$rejected=$true}
    Check $rejected 'Tampered home binding is rejected before rollback'
}finally{[IO.File]::WriteAllText($manifestPath,$original,(New-Object Text.UTF8Encoding($false)))}
$refused=$false;try{& "$experiment\New-BridgeTrial.ps1" -Destination $trial -RealCli $fake -DesktopExecutable $fake|Out-Null}catch{$refused=$true}
Check $refused 'Creating over an existing environment is refused'
Write-TrialJson (Join-Path $output 'result.json') @{passed=$passed;trial=$trial;scope='fixture-only'}
Write-Output ('PASSED: '+$passed+' recovery checks. Output: '+$output)
