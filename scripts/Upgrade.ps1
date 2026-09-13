param(
 [string]$TargetDirectory,
 [string]$LegacySettingsPath=(Join-Path $env:LOCALAPPDATA 'CodexDualLauncher\settings.json'),
 [switch]$CheckOnly,
 [string]$ShortcutDirectory=[Environment]::GetFolderPath('Desktop'),
 [switch]$NoShortcuts
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Upgrade.ps1"
if(-not $TargetDirectory){
 Add-Type -AssemblyName System.Windows.Forms
 $dialog=New-Object Windows.Forms.FolderBrowserDialog
 $dialog.Description='选择旧版工具文件夹（里面有 Start.cmd 和 src），不要选择 Codex 数据目录。'
 try{if($dialog.ShowDialog() -ne 'OK'){return};$TargetDirectory=$dialog.SelectedPath}finally{$dialog.Dispose()}
}
$options=@{Source=(Split-Path $PSScriptRoot -Parent);Target=$TargetDirectory;LegacySettingsPath=$LegacySettingsPath;CheckOnly=$CheckOnly}
if(-not $NoShortcuts){$options.ShortcutDirectory=$ShortcutDirectory}
Invoke-ControllerUpgrade @options | Format-List
