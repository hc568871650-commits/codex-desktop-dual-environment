$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\..\src\Instances.ps1"
. "$PSScriptRoot\..\src\Panel.ps1"
[Windows.Forms.Application]::EnableVisualStyles()
$script:passed=0
function Assert-ExitCheck($Value,$Message){if(-not $Value){throw "FAIL: $Message"};$script:passed++;Write-Output "PASS: $Message"}
function Get-Expected([Diagnostics.Process]$Process){
    for($i=0;$i -lt 10;$i++){$snapshot=@(Get-ProcessSnapshotById $Process.Id);if($snapshot.Count -eq 1){return $snapshot[0]};Start-Sleep -Milliseconds 50}
    throw 'Fixture process did not become observable.'
}
function Start-WaitFixture([int]$Milliseconds){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $info.Arguments='-NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds '+$Milliseconds+'"'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    return [Diagnostics.Process]::Start($info)
}
$panel=New-Object Windows.Forms.Form
$fixtures=New-Object 'Collections.Generic.List[Diagnostics.Process]'
try{
    $short=Start-WaitFixture 2000;$fixtures.Add($short);$expected=Get-Expected $short
    Assert-ExitCheck (-not $short.HasExited -and (Test-ExpectedProcessAlive $expected)) 'Normal-exit fixture is alive before waiting'
    $result=Wait-ExpectedProcessExitUi -Expected $expected -Message '测试正常退出…' -TimeoutMilliseconds 3000 -PassThru
    Assert-ExitCheck $result.Exited 'Progress wait detects a normal exit'
    Assert-ExitCheck ($result.ElapsedMilliseconds -lt 2500) 'Normal exit does not consume the full timeout'
    Assert-ExitCheck ($result.PumpCount -ge 5) 'Progress wait keeps pumping WinForms messages'

    $long=Start-WaitFixture 10000;$fixtures.Add($long);$expected=Get-Expected $long
    Assert-ExitCheck (-not $long.HasExited -and (Test-ExpectedProcessAlive $expected)) 'Timeout fixture is alive before waiting'
    $result=Wait-ExpectedProcessExitUi -Expected $expected -Message '测试超时…' -TimeoutMilliseconds 700 -PassThru
    Assert-ExitCheck (-not $result.Exited) 'Live process reaches the bounded timeout'
    Assert-ExitCheck ($result.ElapsedMilliseconds -ge 650 -and $result.ElapsedMilliseconds -lt 1800) 'Timeout remains bounded without repeated process scans'
}finally{
    $panel.Dispose()
    foreach($fixture in $fixtures){try{if(-not $fixture.HasExited){$fixture.Kill();$fixture.WaitForExit()}}finally{$fixture.Dispose()}}
}
if($script:passed -ne 7){throw 'Exit UI checks were skipped.'}
Write-Output "PASSED: $script:passed exit UI checks"
