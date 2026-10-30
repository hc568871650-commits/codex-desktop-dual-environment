param([Parameter(Mandatory)][string]$Receipt,[switch]$Apply)
$ErrorActionPreference='Stop'
$r=Get-Content -LiteralPath $Receipt -Raw -Encoding UTF8|ConvertFrom-Json
if($r.schema -ne 1 -or -not $r.applied){throw 'Receipt does not describe an applied installation.'}
$target=[IO.Path]::GetFullPath($r.target).TrimEnd('\');$backup=[IO.Path]::GetFullPath($r.backup).TrimEnd('\')
if($target.Length -le 3 -or $backup -ne [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Receipt))){throw 'Invalid rollback roots.'}
function Assert-Plain([string]$Path){for($p=[IO.Path]::GetFullPath($Path);$p;$p=[IO.Path]::GetDirectoryName($p)){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Rollback path contains a reparse point.'}}}
Assert-Plain $target;Assert-Plain $backup
function Atomic([string]$Path,[byte[]]$Bytes){$temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp';try{[IO.File]::WriteAllBytes($temp,$Bytes);if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}}finally{if(Test-Path -LiteralPath $temp){[IO.File]::Delete($temp)}}}
foreach($entry in $r.files){
 if([IO.Path]::IsPathRooted($entry.path) -or $entry.path -match '(^|[\\/])\.\.([\\/]|$)'){throw 'Invalid receipt path.'}
 $path=[IO.Path]::GetFullPath((Join-Path $target $entry.path))
 Assert-Plain $path
 if(-not $path.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Rollback target escaped installation.'}
 if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.afterHash){throw ('Installed file changed; preserved: '+$entry.path)}
 if($entry.beforeExists){if((Get-FileHash -LiteralPath (Join-Path $backup ('files\'+$entry.path)) -Algorithm SHA256).Hash -ne $entry.beforeHash){throw 'Backup checksum mismatch.'}}
}
$launcher=$null
if($r.launcher){Assert-Plain $r.launcher;$text=[IO.File]::ReadAllText($r.launcher);if(-not $text.Contains($r.installedTitleBlock)){throw 'Title integration was changed after installation; preserved.'};$launcher=$text.Replace($r.installedTitleBlock,$r.originalTitleBlock)}
if(-not $Apply){@{ready=$true;target=$target;restoreFiles=@($r.files).Count;launcher=$r.launcher}|ConvertTo-Json;return}
$exe=Join-Path $target 'CodexDualController.exe'
$processes=@(Get-CimInstance Win32_Process -Filter "Name='CodexDualController.exe'"|Where-Object {$_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -eq $exe})
foreach($entry in $processes){
 $p=Get-Process -Id $entry.ProcessId -ErrorAction SilentlyContinue
 if($p){try{
  if([math]::Abs($p.StartTime.ToUniversalTime().Ticks-$entry.CreationDate.ToUniversalTime().Ticks) -ge 10){throw 'Controller identity changed.'}
  $request=Start-Process -FilePath $exe -ArgumentList ('--quit --config "'+$r.config+'"') -WindowStyle Hidden -PassThru
  [void]$request.WaitForExit(5000)
  if(-not $p.WaitForExit(10000)){throw 'Controller did not exit; installation preserved.'}
 }finally{$p.Dispose()}}
}
foreach($entry in $r.files){$path=Join-Path $target $entry.path;if($entry.beforeExists){Atomic $path ([IO.File]::ReadAllBytes((Join-Path $backup ('files\'+$entry.path))))}else{[IO.File]::Delete($path)}}
if($r.launcher){Atomic $r.launcher ((New-Object Text.UTF8Encoding($true)).GetPreamble()+[Text.Encoding]::UTF8.GetBytes($launcher))}
$old=Join-Path $backup 'title-settings.original.json'
Assert-Plain $r.titleSettingsPath
if((Test-Path -LiteralPath $r.titleSettingsPath) -and (Get-FileHash -LiteralPath $r.titleSettingsPath -Algorithm SHA256).Hash -eq $r.titleSettingsAfterHash){
 if(Test-Path -LiteralPath $old){Atomic $r.titleSettingsPath ([IO.File]::ReadAllBytes($old))}else{[IO.File]::Delete($r.titleSettingsPath)}
}
@{rolledBack=$true;at=[DateTimeOffset]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $backup 'rollback.json') -Encoding UTF8
if($processes.Count){Start-Process -FilePath $exe -ArgumentList ('--background --config "'+$r.config+'"') -WindowStyle Hidden}
Write-Output 'Controller and title startup block restored. Codex processes were not stopped.'
