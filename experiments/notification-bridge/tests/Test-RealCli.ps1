param([Parameter(Mandatory=$true)][string]$TrialDirectory)
$ErrorActionPreference='Stop'
$experiment=Split-Path $PSScriptRoot -Parent
. "$experiment\Trial.Common.ps1"
$m=Read-BridgeTrial $TrialDirectory
& (Join-Path $m.root 'Enable-BridgeTrial.ps1') | Out-Null
$start=New-Object Diagnostics.ProcessStartInfo
$start.FileName=Join-Path $m.root 'BridgeProxy.exe';$start.Arguments='app-server';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
foreach($name in @($start.EnvironmentVariables.Keys)){if($name -match '^(CODEX_|OPENAI_|CHATGPT_|ELECTRON_)' -or $name -match '(?i)(API_KEY|ACCESS_TOKEN|AUTH_TOKEN|SECRET_KEY)$' -or $name -eq 'NODE_OPTIONS'){$start.EnvironmentVariables.Remove($name)}}
$start.EnvironmentVariables['CODEX_HOME']=$m.apiHome
$process=[Diagnostics.Process]::Start($start)
$errors=$process.StandardError.ReadToEndAsync()
$passed=0
function Check($condition,[string]$name){if(-not $condition){throw ('FAIL: '+$name)};$script:passed++;Write-Output ('PASS: '+$name)}
function Send($value){$process.StandardInput.WriteLine(($value|ConvertTo-Json -Depth 8 -Compress));$process.StandardInput.Flush()}
function Response([int]$id){
    $limit=[DateTime]::UtcNow.AddSeconds(20)
    do{
        $read=$process.StandardOutput.ReadLineAsync()
        if(-not $read.Wait([Math]::Max(1,[int]($limit-[DateTime]::UtcNow).TotalMilliseconds))){throw 'Timed out waiting for real CLI; no model request was sent.'}
        if($null -eq $read.Result){throw 'Real CLI exited before handshake.'}
        $msg=$read.Result|ConvertFrom-Json
        if($msg.PSObject.Properties['id'] -and $msg.id -eq $id){return $msg}
    }while([DateTime]::UtcNow -lt $limit)
    throw 'No matching real CLI response.'
}
try{
    Send @{id=1;method='initialize';params=@{clientInfo=@{name='codex_dual_bridge_trial';version='0.1.0'};capabilities=@{experimentalApi=$true}}}
    $hello=Response 1
    Check ([bool]$hello.PSObject.Properties['result']) 'Bundled real app-server initialize round trip succeeds'
    Send @{method='initialized'}
    Send @{id=2;method='config/read';params=@{includeLayers=$false}}
    $config=Response 2
    Check ([bool]$config.PSObject.Properties['result']) 'Read-only config request passes through the real CLI connection'
    $cfg=Get-Content (Join-Path $m.root 'bridge.config.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $pipe=New-Object IO.Pipes.NamedPipeClientStream('.',$cfg.pipeName,[IO.Pipes.PipeDirection]::InOut)
    try{
        $pipe.Connect(2500);$writer=New-Object IO.StreamWriter($pipe);$writer.AutoFlush=$true;$reader=New-Object IO.StreamReader($pipe)
        $writer.WriteLine('{"command":"snapshot"}');$read=$reader.ReadLineAsync()
        if(-not $read.Wait(2500)){throw 'Real bridge snapshot timeout'}
        $snapshot=$read.Result|ConvertFrom-Json
        Check ($snapshot.ok -and $snapshot.instanceId -eq $cfg.instanceId -and @($snapshot.pending).Count -eq 0) 'Actual bridge pipe has correct isolated identity and no synthetic questions'
    }finally{$pipe.Dispose()}
    & (Join-Path $m.root 'Rollback-ApiBridge.ps1') | Out-Null
    Send @{id=3;method='config/read';params=@{includeLayers=$false}}
    $after=Response 3
    Check ([bool]$after.PSObject.Properties['result']) 'Real CLI remains responsive after live rollback'
}finally{
    if(-not $process.HasExited){$process.StandardInput.Close();if(-not $process.WaitForExit(7000)){$process.Kill();throw 'Owned trial proxy did not stop on EOF.'}}
    $exit=$process.ExitCode;$process.Dispose()
}
Check ($exit -eq 0) 'Real CLI and proxy exit cleanly on EOF'
Write-TrialJson (Join-Path $m.root 'real-cli-validation.json') @{passed=$passed;modelRequests=0;scope='real-cli-handshake-and-rollback';utc=[DateTime]::UtcNow.ToString('o')}
Write-Output ('PASSED: '+$passed+' real CLI checks. No model request or credentials used.')
