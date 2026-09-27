param([string]$TrialDirectory=$PSScriptRoot,[switch]$WithoutBridge,[switch]$PackageContext)
. "$PSScriptRoot\Trial.Common.ps1"
$m=Read-BridgeTrial $TrialDirectory
$info=New-TrialDesktopStartInfo $m -WithoutBridge:$WithoutBridge
if(-not $PackageContext -and $m.desktopExe -like '*\WindowsApps\*'){
    $package=@(Get-AppxPackage -Name OpenAI.Codex|Where-Object {$m.desktopExe.StartsWith($_.InstallLocation+'\',[StringComparison]::OrdinalIgnoreCase)})
    if($package.Count -ne 1){throw 'Could not identify the exact desktop package for this trial.'}
    Add-Type -Path "$PSScriptRoot\TrialAppx.cs"
    $arguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -TrialDirectory "'+$m.root+'" -PackageContext'
    if($WithoutBridge){$arguments+=' -WithoutBridge'}
    $helper=[CodexBridgeTrial.AppxLauncher]::Start(($package[0].PackageFamilyName+'!App'),"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe",$arguments)
    Write-Output ('Isolated package-context launch requested, helper PID '+$helper+'.');return
}
$p=[Diagnostics.Process]::Start($info)
try{
    Write-TrialJson (Join-Path $m.root 'desktop-process.json') @{schema=1;pid=$p.Id;startedUtc=$p.StartTime.ToUniversalTime().ToString('o');executable=$m.desktopExe;profile=$m.profile;apiHome=$m.apiHome;bridgeRequested=$info.EnvironmentVariables.ContainsKey('CODEX_CLI_PATH')}
    Write-Output ('Isolated desktop launched, PID '+$p.Id+'. This does not prove bridge activation; check the proxy handshake.')
}finally{$p.Dispose()}
