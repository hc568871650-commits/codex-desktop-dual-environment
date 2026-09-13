param(
    [string]$TargetDirectory,[string[]]$SearchDirectories,
    [string]$DataDirectory=(Join-Path $env:LOCALAPPDATA 'CodexDualData'),
    [string]$OfficialHome,[string]$OfficialProfile='', [string]$Executable='',
    [string]$BaseUrl,[string]$Model,[Security.SecureString]$ApiKey,
    [string]$ShortcutDirectory=[Environment]::GetFolderPath('Desktop'),
    [string]$LegacySettingsPath=(Join-Path $env:LOCALAPPDATA 'CodexDualLauncher\settings.json'),
    [switch]$NoShortcuts,[switch]$NoLaunch,[switch]$CheckOnly,[switch]$NonInteractive,
    [string]$RegistryPath='HKCU:\Software\CodexDualController\Installations'
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. "$root\src\Setup.ps1"
$hints=if($TargetDirectory){@()}elseif($PSBoundParameters.ContainsKey('SearchDirectories')){@($SearchDirectories)}else{@(Get-ControllerSetupHints -RegistryPath $RegistryPath -ShortcutDirectory $ShortcutDirectory)}
$planArgs=@{Source=$root;TargetDirectory=$TargetDirectory;Hints=$hints;LegacySettingsPath=$LegacySettingsPath;ShortcutDirectory=$ShortcutDirectory;NoShortcuts=$NoShortcuts}
$plan=Get-ControllerSetupPlan @planArgs
if($CheckOnly){return $plan}
if($plan.Mode -in @('Choose','LocateLegacy')){
    if($NonInteractive){throw ($plan.Reason+' 请用 -TargetDirectory 指定目标目录。')}
    Write-Host $plan.Reason
    foreach($candidate in $plan.Candidates){Write-Host ($candidate.Root+' | '+$(if($candidate.Valid){$candidate.Version}else{$candidate.Reason}))}
    Add-Type -AssemblyName System.Windows.Forms
    $picker=New-Object Windows.Forms.FolderBrowserDialog
    $picker.Description='请选择已有控制器的工具目录，不要选择 CodexHome 或 DesktopProfile 数据目录。'
    try{if($picker.ShowDialog() -ne 'OK'){return};$planArgs.TargetDirectory=$picker.SelectedPath}finally{$picker.Dispose()}
    $plan=Get-ControllerSetupPlan @planArgs
}
if($plan.Mode -eq 'Blocked'){throw ($plan.Target+': '+$plan.Reason)}
Write-Host (@{Install='首次安装';Upgrade='升级或修复';Launch='已是当前版本，直接打开'}[$plan.Mode]+'：'+$plan.Target)
if($plan.Mode -eq 'Install'){
    if($NonInteractive -and (-not $OfficialHome -or -not $BaseUrl -or -not $Model -or -not $ApiKey)){throw '首次安装需要提供 OfficialHome、BaseUrl、Model 和 ApiKey。'}
    & "$PSScriptRoot\Install.ps1" -InstallDirectory $plan.Target -DataDirectory $DataDirectory -OfficialHome $OfficialHome -OfficialProfile $OfficialProfile -Executable $Executable -BaseUrl $BaseUrl -Model $Model -ApiKey $ApiKey -ShortcutDirectory $ShortcutDirectory -NoShortcuts:$NoShortcuts
}elseif($plan.Mode -eq 'Upgrade'){
    while($true){
        try{Assert-UpgradeNotRunning $plan.Target;break}catch{
            if($NonInteractive){throw}
            Add-Type -AssemblyName System.Windows.Forms
            if([Windows.Forms.MessageBox]::Show($_.Exception.Message+' 退出控制器后点击“重试”即可继续，两套 Codex 可以保持运行。','更新控制器','RetryCancel','Information') -ne 'Retry'){return}
        }
    }
    $upgradeArgs=@{Source=$root;Target=$plan.Target;LegacySettingsPath=$LegacySettingsPath}
    if(-not $NoShortcuts){$upgradeArgs.ShortcutDirectory=$ShortcutDirectory}
    Invoke-ControllerUpgrade @upgradeArgs | Out-Host
}
try{Register-ControllerInstallation $plan.Target $RegistryPath}catch{Write-Warning ('工具已就绪，但安装位置登记失败，下次可手动指定目录：'+$_.Exception.Message)}
if(-not $NoLaunch){Start-Process -FilePath (Join-Path $plan.Target 'CodexDualController.exe') -WorkingDirectory $plan.Target -WindowStyle Normal}
Write-Output ([pscustomobject]@{Mode=$plan.Mode;Target=$plan.Target;Version=$plan.Version;Launched=(-not $NoLaunch)})
