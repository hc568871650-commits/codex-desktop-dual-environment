param(
 [string]$TargetDirectory='', [string]$DataDirectory=(Join-Path $env:LOCALAPPDATA 'CodexDualData'),
 [string]$OfficialHome='', [string]$OfficialProfile='', [string]$Executable='',
 [string]$BaseUrl='', [string]$Model='', [Security.SecureString]$ApiKey,
 [string]$ShortcutDirectory=[Environment]::GetFolderPath('Desktop'),
 [string]$BackupDirectory='', [switch]$NoShortcuts, [switch]$NoLaunch,
 [switch]$CheckOnly, [switch]$NonInteractive
)
$ErrorActionPreference='Stop'
$package=Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\DotNet-Package.ps1"
$manifest=Read-DotNetPackage $package
if(-not $TargetDirectory){
 if($NonInteractive){throw 'Specify -TargetDirectory for unattended installation.'}
 $TargetDirectory=Read-Host ('Installation directory (Enter: '+(Join-Path $env:LOCALAPPDATA 'CodexDualController')+')')
 if(-not $TargetDirectory){$TargetDirectory=Join-Path $env:LOCALAPPDATA 'CodexDualController'}
}
$target=[IO.Path]::GetFullPath($TargetDirectory).TrimEnd('\')
if($target -eq $package -or $target.StartsWith($package+'\',[StringComparison]::OrdinalIgnoreCase) -or $package.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Extract the download separately from the installation.'}
if(Test-Path -LiteralPath (Join-Path $target 'instances.local.json')){
 . "$package\src\Instances.ps1"
 [void](Read-ControllerConfig (Join-Path $target 'instances.local.json'))
 $pins=@{}
 foreach($proofName in @('install-manifest.json','dotnet-manifest.json')){
  $proofPath=Join-Path $target $proofName
  if(Test-Path -LiteralPath $proofPath){
   $proof=Get-Content -LiteralPath $proofPath -Raw -Encoding UTF8|ConvertFrom-Json
   if($proof.schema -ne 1){throw 'A valid existing installation manifest is required.'}
   foreach($entry in $proof.files){$pins[$entry.path]=$entry.sha256}
  }
 }
 if(-not $pins.Count){throw 'Existing installation manifest required.'}
 foreach($entry in $manifest.files){
  $path=Join-Path $target $entry.path
  if(Test-Path -LiteralPath $path){
   if(-not $pins.ContainsKey($entry.path) -or (Get-FileHash -LiteralPath $path).Hash -ne $pins[$entry.path]){throw ('Existing file changed or is unowned; preserved: '+$entry.path)}
  }
 }
 $versionPath=Join-Path $target 'version.json'
 if(Test-Path -LiteralPath $versionPath){
  $previous=Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8|ConvertFrom-Json
  if($previous.product -ne 'codex-desktop-dual-environment'){throw 'Different product.'}
  $newBase=[version]($manifest.version -split '-')[0];$oldBase=[version]($previous.version -split '-')[0]
  if($oldBase -gt $newBase -or ($oldBase -eq $newBase -and $previous.version -notmatch '-preview\.')){throw 'Downgrade refused; use the original rollback receipt.'}
  if($oldBase -eq $newBase -and $previous.version -match '-preview\.(\d+)$' -and [int]$Matches[1] -gt [int](($manifest.version -split '\.')[-1])){throw 'Preview downgrade refused.'}
 }
 $exe=Join-Path $target 'CodexDualController.exe'
 if(@(Get-CimInstance Win32_Process -Filter "Name='CodexDualController.exe'"|Where-Object {$_.ExecutablePath -eq $exe}).Count){throw 'Exit this controller before upgrading. Codex can keep running.'}
 if(-not $BackupDirectory){$BackupDirectory=$target+'.backup-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)}
 & "$PSScriptRoot\Install-DotNetLocal.ps1" -Package $package -Target $target -Backup $BackupDirectory -Apply:(-not $CheckOnly)
 if(-not $CheckOnly){Write-Host ('Rollback receipt: '+(Join-Path $BackupDirectory 'receipt.json'))}
}else{
 if($CheckOnly){Write-Output 'Fresh install: requires an empty target, an installed Desktop, and separate official/API data directories.';return}
 if($NonInteractive -and (-not $OfficialHome -or -not $BaseUrl -or -not $Model -or -not $ApiKey)){throw 'Fresh unattended install requires OfficialHome, BaseUrl, Model and ApiKey.'}
 & "$PSScriptRoot\Install.ps1" -InstallDirectory $target -DataDirectory $DataDirectory -OfficialHome $OfficialHome -OfficialProfile $OfficialProfile -Executable $Executable -BaseUrl $BaseUrl -Model $Model -ApiKey $ApiKey -ShortcutDirectory $ShortcutDirectory -NoShortcuts:$NoShortcuts
}
if(-not $CheckOnly -and -not $NoLaunch){Start-Process -FilePath (Join-Path $target 'CodexDualController.exe') -WorkingDirectory $target}
