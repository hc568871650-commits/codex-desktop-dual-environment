param([Parameter(Mandatory)][string]$Package,[Parameter(Mandatory)][string]$OutputDirectory,[string]$LegacyPackage='')
$ErrorActionPreference='Stop'
$Package=[IO.Path]::GetFullPath($Package);$root=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $root){throw 'Test output must be new.'}
[void][IO.Directory]::CreateDirectory($root)
$checks=New-Object Collections.Generic.List[string]
function Check($condition,[string]$name){if(-not $condition){throw ('FAIL: '+$name)};$checks.Add($name);Write-Output ('PASS: '+$name)}
function Reject([scriptblock]$action,[string]$name){$rejected=$false;try{& $action|Out-Null}catch{$rejected=$true};Check $rejected $name}
function Hash([string]$path){(Get-FileHash -LiteralPath $path).Hash}
function Install-Fixture([string]$source,[string]$name){
 # The untouched 0.8.9 installer has a known ANSI WScript shortcut limitation.
 # Exercise Unicode paths in the new installer, and migrate an ASCII legacy installation.
 $folder=if($name -eq 'fresh'){$name+' 中文 space'}else{$name+' space'}
 $target=Join-Path $root ($folder+'\Tool');$data=Join-Path $root ($folder+'\Data');$official=Join-Path $root ($folder+'\Official');$links=Join-Path $root ($folder+'\Links')
 $key=ConvertTo-SecureString 'synthetic-not-a-real-key' -AsPlainText -Force
 & (Join-Path $source 'scripts\Install.ps1') -InstallDirectory $target -DataDirectory $data -OfficialHome $official -Executable "$env:SystemRoot\System32\notepad.exe" -BaseUrl 'https://example.invalid/v1' -Model 'fixture' -ApiKey $key -ShortcutDirectory $links|Out-Host
 return $target
}
function Smoke([string]$target,[string]$theme){
 $config=Join-Path $target 'instances.local.json';$state=Join-Path $root ('ui-'+$theme)
 [void][IO.Directory]::CreateDirectory($state)
 @{schema=1;appearance=@{mode=$theme;accent='neutral'}}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $state 'preferences.local.json') -Encoding UTF8
 $report=Join-Path $root ('ui-'+$theme+'.json')
 $info=New-Object Diagnostics.ProcessStartInfo
 $info.FileName=Join-Path $target 'CodexDualController.exe';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
 $info.Arguments='--trial --smoke-ui --smoke-interactions --config "'+$config+'" --state-directory "'+$state+'" --report "'+$report+'" --screenshots "'+(Join-Path $root ('screenshots-'+$theme))+'"'
 $info.EnvironmentVariables['DOTNET_ROOT']=Join-Path $root 'no-runtime'
 $info.EnvironmentVariables['DOTNET_ROOT_X64']=Join-Path $root 'no-runtime'
 $info.EnvironmentVariables['DOTNET_MULTILEVEL_LOOKUP']='0'
 $p=[Diagnostics.Process]::Start($info)
 try{if(-not $p.WaitForExit(60000)){$p.Kill();throw 'Isolated UI timed out.'};Check ($p.ExitCode -eq 0) ($theme+' UI process exit')}finally{$p.Dispose()}
 Check ((Test-Path -LiteralPath $report) -and -not(Test-Path -LiteralPath ($report+'.exception.json')) -and (Test-Path -LiteralPath ($report+'.exited'))) ($theme+' clean UI report')
 $result=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
 Check ($result.success -and $result.menuSelections -ge 30 -and $result.headerActionsHitTestPassed) ($theme+' dropdown and header interaction')
}
try{
 . (Join-Path $Package 'scripts\DotNet-Package.ps1')
 $manifest=Read-DotNetPackage $Package
 Check $manifest.selfContained 'Self-contained release manifest'
 Check ((Test-Path -LiteralPath (Join-Path $Package 'coreclr.dll')) -and (Test-Path -LiteralPath (Join-Path $Package 'System.Windows.Forms.dll'))) 'Runtime included'
 Check (-not @(Get-ChildItem -LiteralPath $Package -Recurse -File|Where-Object {$_.Name -match '(\.local\.json|\.dpapi|\.log|\.pdb)$' -or $_.Name -eq 'auth.json'}).Count) 'No local settings, credentials or logs'
 $fresh=Install-Fixture $Package 'fresh'
 Check ((Hash (Join-Path $fresh 'CodexDualController.exe')) -eq (Hash (Join-Path $Package 'CodexDualController.exe'))) 'Fresh installation uses prebuilt C# app'
 $freshConfig=Get-Content -LiteralPath (Join-Path $fresh 'instances.local.json') -Raw -Encoding UTF8|ConvertFrom-Json
 $configHash=Hash (Join-Path $fresh 'instances.local.json');$keyPath=Join-Path $freshConfig.instances[1].apiRoot 'Credentials\api-key.dpapi';$keyHash=Hash $keyPath
 $links=Join-Path (Split-Path $fresh -Parent) 'Links'
 $apiLink=[CodexDual.UnicodeShortcut]::Read((Join-Path $links 'Codex API.lnk'))
 Check ($apiLink[0] -eq (Join-Path $fresh 'CodexDualController.exe') -and $apiLink[1].Contains('--open-instance --role api') -and $apiLink[2] -eq $fresh) 'Unicode shortcut roundtrip uses C# entry'
 Smoke $fresh 'dark';Smoke $fresh 'light'
 & (Join-Path $Package 'scripts\Set-DotNetTitle.ps1') -ConfigPath (Join-Path $fresh 'instances.local.json') -Mode enable -Model fixture|Out-Null
 $settings=Get-Content -LiteralPath (Join-Path $freshConfig.stateDirectory 'dotnet-title.local.json') -Raw -Encoding UTF8|ConvertFrom-Json
 Check ($settings.enabled -and $settings.credentialFiles.CODEX_DUAL_API_KEY -eq $keyPath) 'Explicit title enable binds managed encrypted credential'
 & (Join-Path $Package 'scripts\Set-DotNetTitle.ps1') -ConfigPath (Join-Path $fresh 'instances.local.json') -Mode disable|Out-Null
 $settingsHash=Hash (Join-Path $freshConfig.stateDirectory 'dotnet-title.local.json')
 $backup=Join-Path $root 'fresh-backup'
 & (Join-Path $Package 'scripts\Bootstrap-DotNet.ps1') -TargetDirectory $fresh -BackupDirectory $backup -NonInteractive -NoLaunch|Out-Host
 Check ((Hash (Join-Path $fresh 'instances.local.json')) -eq $configHash -and (Hash $keyPath) -eq $keyHash -and (Hash (Join-Path $freshConfig.stateDirectory 'dotnet-title.local.json')) -eq $settingsHash) 'Upgrade preserves configuration, credential and title preference'
 & (Join-Path $Package 'scripts\Rollback-DotNetLocal.ps1') -Receipt (Join-Path $backup 'receipt.json') -Apply|Out-Host
 Check ((Hash (Join-Path $fresh 'instances.local.json')) -eq $configHash -and (Hash $keyPath) -eq $keyHash) 'Rollback preserves data'
 $changed=Join-Path $fresh 'README.md';[IO.File]::AppendAllText($changed,"`r`nUser modification")
 Reject {& (Join-Path $Package 'scripts\Bootstrap-DotNet.ps1') -TargetDirectory $fresh -BackupDirectory (Join-Path $root 'blocked-backup') -NoLaunch -NonInteractive} 'Upgrade refuses modified files'
 & (Join-Path $Package 'scripts\Uninstall-DotNet.ps1') -InstallDirectory $fresh -Apply|Out-Host
 Check ((Test-Path -LiteralPath $changed) -and -not(Test-Path -LiteralPath (Join-Path $fresh 'CodexDualController.exe'))) 'Uninstall preserves edited files and removes owned app'
 Check ((Hash $keyPath) -eq $keyHash -and (Hash (Join-Path $fresh 'instances.local.json')) -eq $configHash) 'Uninstall preserves encrypted credential and recovery config'
 Check (-not(Test-Path -LiteralPath (Join-Path $links 'Codex API.lnk'))) 'Uninstall removes owned shortcut'
 if($LegacyPackage){
  $legacy=Install-Fixture $LegacyPackage 'legacy'
  $before=@{};Get-ChildItem -LiteralPath $legacy -Recurse -File|ForEach-Object {$before[$_.FullName.Substring($legacy.Length+1)]=Hash $_.FullName}
  $legacyBackup=Join-Path $root 'legacy-backup'
  & (Join-Path $Package 'scripts\Bootstrap-DotNet.ps1') -TargetDirectory $legacy -BackupDirectory $legacyBackup -NoLaunch -NonInteractive|Out-Host
  Check ((Hash (Join-Path $legacy 'CodexDualController.exe')) -eq (Hash (Join-Path $Package 'CodexDualController.exe'))) 'Public 0.8.9 upgrades to C#'
  $legacyConfig=Get-Content -LiteralPath (Join-Path $legacy 'instances.local.json') -Raw -Encoding UTF8|ConvertFrom-Json
  Check (-not (Get-Content -LiteralPath (Join-Path $legacyConfig.stateDirectory 'dotnet-title.local.json') -Raw -Encoding UTF8|ConvertFrom-Json).enabled) 'Migration does not enable title hooking'
  $receipt=Join-Path $legacyBackup 'receipt.json'
  & (Join-Path $Package 'scripts\Rollback-DotNetLocal.ps1') -Receipt $receipt -Apply|Out-Host
  foreach($relative in $before.Keys){if((Hash (Join-Path $legacy $relative)) -ne $before[$relative]){throw ('Rollback mismatch: '+$relative)}}
  Check ($true) 'Legacy rollback restores every original file byte-for-byte'
  $after=@(Get-ChildItem -LiteralPath $legacy -Recurse -File)
  Check ($after.Count -eq $before.Count) 'Legacy rollback removes all added tool files'
 }
 @{success=$true;checks=$checks;count=$checks.Count;modelCalls=0;desktopLaunches=0}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $root 'report.json') -Encoding UTF8
}catch{
 @{success=$false;checks=$checks;error=$_.Exception.Message}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $root 'report.json') -Encoding UTF8
 throw
}
