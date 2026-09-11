param([string]$Snapshot)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Upgrade.ps1"
if(-not $Snapshot){Add-Type -AssemblyName System.Windows.Forms;$dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='选择 upgrades 下含 upgrade.local.json 的升级备份文件夹';try{if($dialog.ShowDialog() -ne 'OK'){return};$Snapshot=$dialog.SelectedPath}finally{$dialog.Dispose()}}
Undo-ControllerUpgrade $Snapshot
