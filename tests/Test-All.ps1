param([switch]$IncludeDesktop)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath("$PSScriptRoot\..")
$output=Join-Path $root ('test-results\validation-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss'))
[void][IO.Directory]::CreateDirectory($output)
$checks=@(
    @{file='Test-Core.ps1';args=@()},@{file='Test-Instances.ps1';args=@('-Integration')},
    @{file='Test-Install.ps1';args=@()},@{file='Test-Upgrade.ps1';args=@()},@{file='Test-Setup.ps1';args=@()},
    @{file='Test-Experience.ps1';args=@()},@{file='Test-ExitUi.ps1';args=@()},
    @{file='Test-Controller.ps1';args=@()},@{file='Test-Host.ps1';args=@()}
)
if($IncludeDesktop){$checks+=@(@{file='Test-Desktop.ps1';args=@('-RunIsolatedDesktop','-CleanupFixtures')})}
$summary=@()
foreach($check in $checks){
    $log=Join-Path $output ($check.file+'.log');$arguments=$check.args
    $ErrorActionPreference='Continue'
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $check.file) @arguments > $log 2>&1
    $code=$LASTEXITCODE;$ErrorActionPreference='Stop'
    $summary+=@{test=$check.file;exitCode=$code;log=$log}
    [IO.File]::WriteAllText((Join-Path $output 'summary.json'),($summary|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
    if($code -ne 0){Get-Content -LiteralPath $log;throw ('检查失败：'+$check.file)}
    Write-Output ('PASS: '+$check.file)
}
Write-Output ('全部检查通过。日志：'+$output)
