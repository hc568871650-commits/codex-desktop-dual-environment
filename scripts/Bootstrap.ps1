$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. "$root\src\Upgrade.ps1"
$config=Join-Path $root 'instances.local.json'
$legacy=Join-Path $env:LOCALAPPDATA 'CodexDualLauncher\settings.json'
if((Test-Path -LiteralPath $config) -or (Test-Path -LiteralPath $legacy)){
    # A current running controller can service the request; never upgrade its files while loaded.
    $hostPath=Join-Path $root 'CodexDualController.exe'
    $running=@(Get-ProcessSnapshot | Where-Object {Test-SamePath $_.Path $hostPath})
    if($running.Count -eq 0){Invoke-ControllerUpgrade -Source $root -Target $root -LegacySettingsPath $legacy | Out-Host}
    if(-not (Test-Path -LiteralPath $hostPath)){throw '控制器程序缺失，请运行 Upgrade.cmd 修复。'}
    Start-Process -FilePath $hostPath -WorkingDirectory $root -WindowStyle Normal
}else{
    & "$PSScriptRoot\Install.ps1"
    $installed=Join-Path $env:LOCALAPPDATA 'CodexDualController\CodexDualController.exe'
    if(Test-Path -LiteralPath $installed){Start-Process -FilePath $installed -WindowStyle Normal}
}
