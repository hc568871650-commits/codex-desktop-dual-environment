param(
    [Parameter(Mandatory=$true)][string]$Destination,
    [Parameter(Mandatory=$true)][string]$RealCli,
    [Parameter(Mandatory=$true)][string]$DesktopExecutable,
    [switch]$TakeoverQuestions
)
. "$PSScriptRoot\Trial.Common.ps1"
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Build with Windows PowerShell 5.1.'}
$root=Assert-PlainTrialPath $Destination
if(Test-Path -LiteralPath $root){throw 'Destination must be new; existing directories are never reused.'}
$cli=Assert-PlainTrialPath $RealCli;$desktop=Assert-PlainTrialPath $DesktopExecutable
foreach($exe in @($cli,$desktop)){if(-not (Test-Path -LiteralPath $exe -PathType Leaf) -or [IO.Path]::GetExtension($exe) -ne '.exe'){throw 'Select existing CLI and desktop executable files.'}}
[void][IO.Directory]::CreateDirectory($root)
# Experimental bundle contains no copied authentication, profile, or chat history.
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
Set-Acl -LiteralPath $root -AclObject $acl
foreach($sub in @('CodexHome','DesktopProfile','Projects')){[void][IO.Directory]::CreateDirectory((Join-Path $root $sub))}
$id=[Guid]::NewGuid().ToString('N')
[IO.File]::WriteAllText((Join-Path $root 'DISABLED'),'Created disabled. Enable only this isolated trial.')
foreach($file in @('Trial.Common.ps1','Start-BridgeTrial.ps1','Rollback-ApiBridge.ps1','Enable-BridgeTrial.ps1','Open-TrialTask.ps1','TrialAppx.cs')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $root $file)}
& "$PSScriptRoot\Build-Bridge.ps1" -Destination (Join-Path $root 'BridgeProxy.exe')
& "$PSScriptRoot\Build-QuestionClient.ps1" -Destination (Join-Path $root 'QuestionClient.exe')
$config=@{realCli=$cli;apiHome=(Join-Path $root 'CodexHome');pipeName=('codex-api-question-trial-'+$id);instanceId=('api-trial-'+$id)}
if($TakeoverQuestions){$config.takeoverQuestions=$true;$config.multiConnection=$true}
Write-TrialJson (Join-Path $root 'bridge.config.json') $config
$manifest=@{schema=1;kind='isolated-api-bridge-trial';id=$id;root=$root;apiHome=$config.apiHome;profile=(Join-Path $root 'DesktopProfile');projects=(Join-Path $root 'Projects');realCli=$cli;realCliHash=(Get-FileHash -LiteralPath $cli).Hash;desktopExe=$desktop;desktopHash=(Get-FileHash -LiteralPath $desktop).Hash;proxyHash=(Get-FileHash -LiteralPath (Join-Path $root 'BridgeProxy.exe')).Hash;createdUtc=[DateTime]::UtcNow.ToString('o');originalInstallationModified=$false}
Write-TrialJson (Join-Path $root 'trial.json') $manifest
$commands=@{
    'Rollback-ApiBridge.cmd'='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Rollback-ApiBridge.ps1"'
    'Start-WithoutBridge.cmd'='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-BridgeTrial.ps1" -WithoutBridge'
    'Start-BridgeTrial.cmd'='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-BridgeTrial.ps1"'
    'Enable-BridgeTrial.cmd'='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Enable-BridgeTrial.ps1"'
    'Open-Questions.cmd'='start "" "%~dp0QuestionClient.exe"'
}
foreach($entry in $commands.GetEnumerator()){
    $finish=if($entry.Key -eq 'Rollback-ApiBridge.cmd'){'pause'}else{'if errorlevel 1 pause'}
    [IO.File]::WriteAllText((Join-Path $root $entry.Key),('@echo off'+"`r`n"+$entry.Value+"`r`n"+$finish+"`r`n"),(New-Object Text.ASCIIEncoding))
}
Write-Output $root
