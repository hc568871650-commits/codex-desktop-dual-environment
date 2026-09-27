$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1 -STA.'}
$experiment=Split-Path $PSScriptRoot -Parent
. (Join-Path $experiment 'Trial.Common.ps1')
$repo=[IO.Path]::GetFullPath((Join-Path $experiment '..\..'))
$output=Join-Path $repo ('test-results\bridge-question-ui-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($output)
$fake=Join-Path $output 'Fake.exe'
& "$PSScriptRoot\Build-FakeAppServer.ps1" -Destination $fake | Out-Null
$trial=Join-Path $output 'Trial'
& "$experiment\New-BridgeTrial.ps1" -Destination $trial -RealCli $fake -DesktopExecutable $fake | Out-Null
& "$trial\Enable-BridgeTrial.ps1" | Out-Null
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -Path "$experiment\QuestionClient.cs" -ReferencedAssemblies System.dll,System.Core.dll,System.Drawing.dll,System.Windows.Forms.dll,System.Web.Extensions.dll
$start=New-Object Diagnostics.ProcessStartInfo
$start.FileName=Join-Path $trial 'BridgeProxy.exe';$start.Arguments='app-server';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
$start.EnvironmentVariables['CODEX_HOME']=Join-Path $trial 'CodexHome'
$process=[Diagnostics.Process]::Start($start)
$window=$null;$script:passed=0
function Check($condition,[string]$name){if(-not $condition){throw ('FAIL: '+$name)};$script:passed++;Write-Output ('PASS: '+$name)}
function PumpUntil([scriptblock]$condition,[string]$name){$limit=[DateTime]::UtcNow.AddSeconds(8);do{[Windows.Forms.Application]::DoEvents();if(& $condition){return};Start-Sleep -Milliseconds 15}while([DateTime]::UtcNow -lt $limit);throw ('Timeout: '+$name)}
function ReadNative(){ $task=$process.StandardOutput.ReadLineAsync();if(-not $task.Wait(5000)){throw 'No fixture response'};return ($task.Result|ConvertFrom-Json) }
try{
    [void](ReadNative);[void](ReadNative);[void](ReadNative)
    $window=New-Object CodexBridgeTrial.QuestionWindow($trial);$window.Show()
    $pending=$window.Controls.Find('PendingRequests',$true)[0]
    PumpUntil {$pending.Items.Count -eq 1} 'question snapshot'
    Check ($pending.Items.Count -eq 1) 'Live pipe question appears in the window'
    $button=$window.Controls.Find('SubmitAnswer',$true)[0];$status=$window.Controls.Find('Status',$true)[0]
    $button.PerformClick();Check ($status.Text -like '*请为每个问题*') 'No default or incomplete answer is submitted'
    $radio=$window.Controls.Find('Option_choice_1',$true)[0];$radio.Checked=$true
    $answer=$window.Controls.Find('Answer_detail',$true)[0];$answer.Text='隔离回答-测试'
    Check $answer.UseSystemPasswordChar 'Secret input is masked'
    $bitmap=New-Object Drawing.Bitmap($window.Width,$window.Height)
    try{$window.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$window.Width,$window.Height)));$bitmap.Save((Join-Path $output 'question-window.png'))}finally{$bitmap.Dispose()}
    $button.PerformClick()
    PumpUntil {$pending.Items.Count -eq 0} 'question clears after answer'
    $one=ReadNative;$two=ReadNative
    $received=@($one,$two|Where-Object {$_.method -eq 'mock/received'})[0]
    Check ($received.params.message.id -eq 42) 'UI answer preserves original JSON-RPC request ID'
    Check ($received.params.message.result.answers.choice.answers[0] -eq 'B' -and $received.params.message.result.answers.detail.answers[0] -ceq '隔离回答-测试') 'Selection and Unicode text reach the mock server exactly'
    Check (@($one,$two|Where-Object {$_.method -eq 'serverRequest/resolved'}).Count -eq 1) 'Native UI receives a resolved event'
    & "$trial\Rollback-ApiBridge.ps1" | Out-Null
    PumpUntil {$status.Text -like '*桥接已停用*'} 'rollback reflected by window'
    Check (-not $button.Enabled) 'Rollback disables direct answering without closing the native task'
    $window.Close();$window=$null
    $process.StandardInput.WriteLine('{"id":99,"result":{"native":"still-alive"}}')
    $native=ReadNative
    Check ($native.params.message.id -eq 99) 'Closing client and rollback leave native transport available'
}finally{
    if($window){$window.Dispose()}
    if(-not $process.HasExited){$process.StandardInput.Close();if(-not $process.WaitForExit(5000)){$process.Kill()}}
    $process.Dispose()
}
Write-TrialJson (Join-Path $output 'result.json') @{passed=$script:passed;scope='fixture-ui-and-pipe';trial=$trial}
Write-Output ('PASSED: '+$script:passed+' UI checks. Output: '+$output)
