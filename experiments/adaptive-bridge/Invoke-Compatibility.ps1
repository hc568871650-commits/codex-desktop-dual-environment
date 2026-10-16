[CmdletBinding()]
param([Parameter(Mandatory)][string]$CliPath,[Parameter(Mandatory)][string]$ProxyPath,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$fixture=Join-Path $PSScriptRoot 'bin\RealCliQuestionFixture.exe'
foreach($path in @($CliPath,$ProxyPath,$fixture,$OutputDirectory)){
 if(-not [IO.Path]::IsPathRooted($path) -or $path.StartsWith('\\') -or $path -match '["\r\n]'){throw 'COMPATIBILITY_PATH_INVALID'}
 $cursor=[IO.Path]::GetFullPath($path)
 while($cursor){if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'COMPATIBILITY_REPARSE_REJECTED'};$cursor=Split-Path $cursor -Parent}
}
$cliHash=(Get-FileHash -LiteralPath $CliPath -Algorithm SHA256).Hash
$proxyHash=(Get-FileHash -LiteralPath $ProxyPath -Algorithm SHA256).Hash
[void][IO.Directory]::CreateDirectory($OutputDirectory)
if(Test-Path -LiteralPath (Join-Path $OutputDirectory 'report.json')){throw 'COMPATIBILITY_OUTPUT_NOT_EMPTY'}
$checks=@()
foreach($case in @(@{name='sync';mode='sync';code='False';multi='False'},@{name='async';mode='async';code='True';multi='False'},@{name='multiconnection';mode='async';code='True';multi='True'})){
 $passed=$false;$reason='FIXTURE_FAILED';$process=$null
 try {
  $directory=Join-Path $OutputDirectory $case.name
  if(Test-Path -LiteralPath $directory){throw 'COMPATIBILITY_CASE_EXISTS'}
  [void][IO.Directory]::CreateDirectory($directory)
  $proxy=Join-Path $directory 'BridgeProxy.exe';Copy-Item -LiteralPath $ProxyPath -Destination $proxy
  if((Get-FileHash -LiteralPath $proxy -Algorithm SHA256).Hash -ne $proxyHash){throw 'COMPATIBILITY_COPY_CHANGED'}
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=$fixture;$start.WorkingDirectory=$directory;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $start.Arguments='"'+$CliPath+'" "'+$proxy+'" "'+$directory+'" '+$case.mode+' '+$case.code+' '+$case.multi
  $allow=@('SystemRoot','WINDIR','PATH','TEMP','TMP','USERPROFILE','LOCALAPPDATA','APPDATA','COMSPEC','SystemDrive','NUMBER_OF_PROCESSORS','PROCESSOR_ARCHITECTURE','PROCESSOR_IDENTIFIER','PATHEXT')
  foreach($name in @($start.EnvironmentVariables.Keys)){if($name -notin $allow){$start.EnvironmentVariables.Remove($name)}}
  $process=New-Object Diagnostics.Process;$process.StartInfo=$start;[void]$process.Start()
  $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  if(-not $process.WaitForExit(120000)){$reason='FIXTURE_TIMEOUT';throw $reason}
  $process.WaitForExit()
  if($process.ExitCode -ne 0){throw 'FIXTURE_FAILED'}
  $evidencePath=Join-Path $directory 'evidence.json'
  if((Get-Item -LiteralPath $evidencePath).Length -gt 1048576){throw 'FIXTURE_EVIDENCE_OVERSIZE'}
  $evidence=[IO.File]::ReadAllText($evidencePath)|ConvertFrom-Json
  if($evidence.success -cne $true -or $evidence.bridgeAnswerAccepted -cne $true -or $evidence.answerReachedRuntime -cne $true -or $evidence.nativeQuestions -ne 0 -or $evidence.mode -cne $case.mode -or $evidence.multiConnection -ne [bool]::Parse($case.multi) -or $evidence.codeModeHost -ne [bool]::Parse($case.code)){throw 'FIXTURE_EVIDENCE_REJECTED'}
  if((Get-FileHash -LiteralPath $CliPath -Algorithm SHA256).Hash -ne $cliHash -or (Get-FileHash -LiteralPath $ProxyPath -Algorithm SHA256).Hash -ne $proxyHash){throw 'COMPATIBILITY_RUNTIME_CHANGED'}
  $passed=$true;$reason='PASSED'
 }catch{}finally{
  if($process){try{if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(3000)}}catch{};$process.Dispose()}
 }
 $checks+=@{name=$case.name;success=$passed;reason=$reason}
}
$report=@{schema=1;success=(@($checks|Where-Object {-not $_.success}).Count -eq 0);cliHash=$cliHash;proxyHash=$proxyHash;suiteVersion='adaptive-protocol-v1';checks=$checks;testedUtc=[DateTime]::UtcNow.ToString('o');scope='isolated real CLI with local Responses fixture'}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'report.json'),($report|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
$report|ConvertTo-Json -Depth 6
