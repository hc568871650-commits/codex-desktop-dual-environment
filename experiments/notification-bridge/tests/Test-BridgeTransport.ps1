$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use Windows PowerShell 5.1.' }
$experiment = Split-Path $PSScriptRoot -Parent
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('bridge-transport-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
& (Join-Path $PSScriptRoot 'Build-FakeAppServer.ps1') -Destination (Join-Path $tempRoot 'FakeAppServer.exe') | Out-Null

function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Read-Line($stream) {
    $task = $stream.ReadLineAsync()
    if (-not $task.Wait(5000)) { throw 'Timed out waiting for mock stdout.' }
    if ($null -eq $task.Result) { throw 'Unexpected mock EOF.' }
    return ($task.Result | ConvertFrom-Json)
}
function Start-Case([string]$name, [bool]$disabled = $false, [string[]]$arguments = @('app-server')) {
    $directory = Join-Path $tempRoot $name
    [void][IO.Directory]::CreateDirectory($directory)
    $taskHome = Join-Path $directory 'api-home'
    [void][IO.Directory]::CreateDirectory($taskHome)
    $bridge = Join-Path $directory 'BridgeProxy.exe'
    & (Join-Path $experiment 'Build-Bridge.ps1') -Destination $bridge | Out-Null
    $fake = Join-Path $directory 'FakeAppServer.exe'
    Copy-Item -LiteralPath (Join-Path $tempRoot 'FakeAppServer.exe') -Destination $fake
    $pipeName = 'bridge-test-' + [guid]::NewGuid().ToString('N')
    @{ realCli = $fake; apiHome = $taskHome; pipeName = $pipeName; instanceId = $name } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $directory 'bridge.config.json') -Encoding UTF8
    if ($disabled) { [IO.File]::WriteAllText((Join-Path $directory 'DISABLED'), '') }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $bridge
    $start.Arguments = ($arguments -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['CODEX_HOME'] = $taskHome
    $process = [Diagnostics.Process]::Start($start)
    return @{ Process = $process; Pipe = $pipeName; Directory = $directory }
}
function Connect-Pipe([string]$name) {
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $name, [IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(3000)
    return @{ Pipe = $pipe; Reader = (New-Object IO.StreamReader($pipe)); Writer = (New-Object IO.StreamWriter($pipe)) }
}
function Command($client, $command) {
    $client.Writer.AutoFlush = $true
    $client.Writer.WriteLine(($command | ConvertTo-Json -Compress -Depth 16))
    return (Read-Line $client.Reader)
}
function Close-Case($case) {
    $case.Process.StandardInput.Close()
    Assert ($case.Process.WaitForExit(5000)) 'Bridge failed to exit on stdin EOF.'
    Assert ($case.Process.ExitCode -eq 0) ('Bridge exit: ' + $case.Process.StandardError.ReadToEnd())
    $case.Process.Dispose()
}
function Start-SameCase($case) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $case.Directory 'BridgeProxy.exe'
    $start.Arguments = 'app-server'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['CODEX_HOME'] = Join-Path $case.Directory 'api-home'
    $start.EnvironmentVariables['CODEX_CLI_PATH'] = $start.FileName
    return @{ Process = [Diagnostics.Process]::Start($start); Pipe = $case.Pipe; Directory = $case.Directory }
}
$answer = @{ choice = @{ answers = @('B') }; detail = @{ answers = @('private answer') } }
$results = @()

Write-Output 'RUN external'
$case = Start-Case 'external'
try {
    $unknown = Read-Line $case.Process.StandardOutput
    Assert ($unknown.method -eq 'mock/unknown') 'Unknown notification missing.'
    Assert ($unknown.params.cliPath -eq (Join-Path $case.Directory 'FakeAppServer.exe')) 'Child CODEX_CLI_PATH still points to proxy.'
    Assert ((Read-Line $case.Process.StandardOutput).method -eq 'item/tool/requestOptionPicker') 'Unknown server request missing.'
    $request = Read-Line $case.Process.StandardOutput
    Assert ($request.id -eq 42) 'Original request ID changed.'
    $client = Connect-Pipe $case.Pipe
    try {
        $pending = (Command $client @{ command = 'snapshot' }).pending[0]
        Assert ($pending.requestId -eq 42 -and $pending.questions.Count -eq 2) 'Snapshot lost request.'
        Assert ($pending.questions[1].isSecret) 'Secret flag lost.'
        $wrong = @{ command='answer'; connectionId=$pending.connectionId; requestToken=$pending.requestToken; requestId=42; threadId='wrong'; turnId=$pending.turnId; answers=$answer }
        Assert ((Command $client $wrong).error -eq 'stale') 'Mismatched thread accepted.'
        $wrong.threadId = $pending.threadId
        $wrong.answers = @{ unknown = @{ answers = @('bad') } }
        Assert ((Command $client $wrong).error -eq 'invalid') 'Unknown question accepted.'
        $wrong.answers = $answer
        Assert ((Command $client $wrong).ok) 'External answer failed.'
        Assert ((Command $client $wrong).error -eq 'stale') 'Repeated answer accepted.'
        Assert ((Command $client @{ command='snapshot' }).pending.Count -eq 0) 'Resolved item remains pending.'
    } finally { $client.Pipe.Dispose() }
    Assert ((Read-Line $case.Process.StandardOutput).method -eq 'serverRequest/resolved') 'Native resolved event missing.'
    $received = Read-Line $case.Process.StandardOutput
    Assert ($received.params.message.id -eq 42 -and $received.params.message.result.answers.choice.answers[0] -eq 'B') 'External response not forwarded.'
    [IO.File]::WriteAllText((Join-Path $case.Directory 'DISABLED'), '')
    $case.Process.StandardInput.WriteLine('{"id":42,"result":{"answers":{}}}')
    $case.Process.StandardInput.WriteLine('{"id":43,"result":{}}')
    $received = Read-Line $case.Process.StandardOutput
    Assert ($received.params.message.id -eq 43) 'Unknown/native response lost or duplicate answer forwarded after rollback.'
    $results += 'external arbitration, binding, validation, unknown request/notification'
} finally { Close-Case $case }

Write-Output 'RUN native'
$case = Start-Case 'native'
try {
    1..3 | ForEach-Object { [void](Read-Line $case.Process.StandardOutput) }
    $client = Connect-Pipe $case.Pipe
    try {
        $pending = (Command $client @{ command='snapshot' }).pending[0]
        $case.Process.StandardInput.WriteLine('{"id":42,"result":{"answers":{}}}')
        $received = Read-Line $case.Process.StandardOutput
        Assert ($received.params.message.id -eq 42) 'Native answer not forwarded.'
        Assert ((Command $client @{ command='answer'; connectionId=$pending.connectionId; requestToken=$pending.requestToken; requestId=42; threadId=$pending.threadId; turnId=$pending.turnId; answers=$answer }).error -eq 'stale') 'External answer won after native.'
    } finally { $client.Pipe.Dispose() }
    $results += 'native-first race'
} finally { Close-Case $case }

Write-Output 'RUN disconnect'
$case = Start-Case 'disconnect'
try {
    1..3 | ForEach-Object { [void](Read-Line $case.Process.StandardOutput) }
    $client = Connect-Pipe $case.Pipe
    Assert ((Command $client @{ command='snapshot' }).pending.Count -eq 1) 'Missing pending request.'
    $client.Pipe.Dispose()
    $client = Connect-Pipe $case.Pipe
    try { Assert ((Command $client @{ command='snapshot' }).pending.Count -eq 1) 'Disconnected client removed native pending request.' }
    finally { $client.Pipe.Dispose() }
    $case.Process.StandardInput.WriteLine('{"id":42,"result":{"answers":{}}}')
    Assert ((Read-Line $case.Process.StandardOutput).params.message.id -eq 42) 'Native answer unavailable after client disconnect.'
    $results += 'pipe disconnect and reconnect'
} finally { Close-Case $case }

Write-Output 'RUN runtime-disable'
$case = Start-Case 'runtime-disable'
try {
    1..3 | ForEach-Object { [void](Read-Line $case.Process.StandardOutput) }
    $client = Connect-Pipe $case.Pipe
    try {
        $pending = (Command $client @{ command='snapshot' }).pending[0]
        [IO.File]::WriteAllText((Join-Path $case.Directory 'DISABLED'), '')
        Assert ((Command $client @{ command='answer'; connectionId=$pending.connectionId; requestToken=$pending.requestToken; requestId=42; threadId=$pending.threadId; turnId=$pending.turnId; answers=$answer }).error -eq 'disabled') 'Live disable accepted answer.'
        Assert ((Command $client @{ command='snapshot' }).pending.Count -eq 0) 'Live disable retained pending.'
    } finally { $client.Pipe.Dispose() }
    $case.Process.StandardInput.WriteLine('{"id":42,"result":{"answers":{}}}')
    Assert ((Read-Line $case.Process.StandardOutput).params.message.id -eq 42) 'Native answer unavailable after live disable.'
    $results += 'running DISABLED fallback'
} finally { Close-Case $case }

Write-Output 'RUN startup-disable'
$case = Start-Case 'startup-disable' $true
try {
    1..3 | ForEach-Object { [void](Read-Line $case.Process.StandardOutput) }
    try { $client = Connect-Pipe $case.Pipe; $client.Pipe.Dispose(); throw 'DISABLED opened event pipe.' }
    catch [TimeoutException] { }
    $case.Process.StandardInput.WriteLine('{"id":42,"result":{"answers":{}}}')
    Assert ((Read-Line $case.Process.StandardOutput).params.message.id -eq 42) 'Disabled passthrough failed.'
    $results += 'startup DISABLED passthrough'
} finally { Close-Case $case }

Write-Output 'RUN other-command'
$case = Start-Case 'other-command' $false @('--version')
try {
    Assert ((Read-Line $case.Process.StandardOutput).params.argv[0] -eq '--version') 'Other CLI command args changed.'
    $case.Process.StandardInput.WriteLine('literal text')
    Assert ($case.Process.StandardOutput.ReadLine() -eq 'literal text') 'Other CLI stdin/stdout changed.'
    $results += 'other CLI transparent forwarding'
} finally { Close-Case $case }

Write-Output 'RUN prefixed-stdio'
$case = Start-Case 'prefixed-stdio' $false @('-c','trial=true','app-server','--listen','stdio://')
try {
    1..3 | ForEach-Object { [void](Read-Line $case.Process.StandardOutput) }
    $client = Connect-Pipe $case.Pipe
    try { Assert ((Command $client @{ command='snapshot' }).pending.Count -eq 1) 'Prefixed stdio app-server not bridged.' }
    finally { $client.Pipe.Dispose() }
    $results += 'global CLI options and explicit stdio listen'
} finally { Close-Case $case }

Write-Output 'RUN reused-id'
$case = Start-Case 'reused-id'
try {
    1..3 | ForEach-Object { [void](Read-Line $case.Process.StandardOutput) }
    $client = Connect-Pipe $case.Pipe
    try {
        $first = (Command $client @{ command='snapshot' }).pending[0]
        $command = @{ command='answer'; connectionId=$first.connectionId; requestToken=$first.requestToken; requestId=42; threadId=$first.threadId; turnId=$first.turnId; answers=$answer }
        Assert ((Command $client $command).ok) 'First answer failed.'
        1..2 | ForEach-Object { [void](Read-Line $case.Process.StandardOutput) }
        $case.Process.StandardInput.WriteLine('{"method":"mock/reuse"}')
        Assert ((Read-Line $case.Process.StandardOutput).params.itemId -eq 'mock-item-2') 'Reused ID request missing.'
        $second = (Command $client @{ command='snapshot' }).pending[0]
        Assert ($second.requestToken -ne $first.requestToken) 'Reused ID retained token.'
        Assert ((Command $client $command).error -eq 'stale') 'Stale request token accepted.'
        $command.requestToken = $second.requestToken
        $command.answers = @{ choice = @{ answers = @('A') } }
        Assert ((Command $client $command).ok) 'Reused request ID rejected.'
        1..2 | ForEach-Object { [void](Read-Line $case.Process.StandardOutput) }
        $results += 'reused ID with distinct request token'
    } finally { $client.Pipe.Dispose() }
} finally { Close-Case $case }

Write-Output 'RUN resolved-and-completed'
$case = Start-Case 'resolved-and-completed'
try {
    1..3 | ForEach-Object { [void](Read-Line $case.Process.StandardOutput) }
    $client = Connect-Pipe $case.Pipe
    try {
        $case.Process.StandardInput.WriteLine('{"method":"mock/resolve"}')
        Assert ((Read-Line $case.Process.StandardOutput).method -eq 'serverRequest/resolved') 'Resolved event missing.'
        Assert ((Command $client @{ command='snapshot' }).pending.Count -eq 0) 'Resolved request not cleared.'
        $case.Process.StandardInput.WriteLine('{"method":"mock/reuse"}')
        [void](Read-Line $case.Process.StandardOutput)
        Assert ((Command $client @{ command='snapshot' }).pending.Count -eq 1) 'Second request missing.'
        $case.Process.StandardInput.WriteLine('{"method":"mock/complete"}')
        Assert ((Read-Line $case.Process.StandardOutput).method -eq 'turn/completed') 'Turn completed missing.'
        Assert ((Command $client @{ command='snapshot' }).pending.Count -eq 0) 'Nested turn.id failed to clear pending.'
        $results += 'serverRequest/resolved and nested turn completion cleanup'
    } finally { $client.Pipe.Dispose() }
} finally { Close-Case $case }

Write-Output 'RUN string-id-and-interruption'
$case = Start-Case 'string-id-and-interruption' $false @('app-server','--string-id')
try {
    1..3 | ForEach-Object { [void](Read-Line $case.Process.StandardOutput) }
    $client = Connect-Pipe $case.Pipe
    try {
        $first = (Command $client @{ command='snapshot' }).pending[0]
        Assert ($first.requestId -ceq 'request-42') 'String request ID changed.'
        $bad = @{ command='answer'; connectionId=$first.connectionId; requestToken=$first.requestToken; requestId=42; threadId=$first.threadId; turnId=$first.turnId; answers=$answer }
        Assert ((Command $client $bad).error -eq 'stale') 'Numeric ID matched string ID.'
        $case.Process.StandardInput.WriteLine('{"method":"turn/interrupt","params":{"threadId":"mock-thread","turnId":"mock-turn"}}')
        Assert ((Read-Line $case.Process.StandardOutput).method -eq 'mock/received') 'Interruption request was not forwarded.'
        Assert ((Command $client @{ command='snapshot' }).pending.Count -eq 0) 'Interruption left request pending.'
        $case.Process.StandardInput.WriteLine('{"method":"mock/reuse"}')
        [void](Read-Line $case.Process.StandardOutput)
        $second = (Command $client @{ command='snapshot' }).pending[0]
        $bad.requestId = 'request-42'; $bad.requestToken = $second.requestToken
        $bad.answers = @{ choice = @{ answers = @('A') } }
        Assert ((Command $client $bad).ok) 'String ID answer failed.'
        Assert ((Read-Line $case.Process.StandardOutput).params.requestId -ceq 'request-42') 'Resolved string ID changed.'
        Assert ((Read-Line $case.Process.StandardOutput).params.message.id -ceq 'request-42') 'Child response string ID changed.'
        $results += 'string ID type and interruption cleanup'
    } finally { $client.Pipe.Dispose() }
} finally { Close-Case $case }

Write-Output 'RUN app-server-subcommand'
$case = Start-Case 'app-server-subcommand' $false @('app-server','generate-json-schema')
try {
    Assert ((Read-Line $case.Process.StandardOutput).params.argv[1] -eq 'generate-json-schema') 'App-server subcommand args changed.'
    try { $client = Connect-Pipe $case.Pipe; $client.Pipe.Dispose(); throw 'Subcommand started event pipe.' }
    catch [TimeoutException] { }
    $results += 'app-server subcommand passthrough'
} finally { Close-Case $case }

Write-Output 'RUN child-exit'
$case = Start-Case 'child-exit' $false @('app-server','--mock-exit')
try {
    Assert ((Read-Line $case.Process.StandardOutput).method -eq 'mock/unknown') 'Early child output missing.'
    Assert ($case.Process.WaitForExit(5000)) 'Bridge remained after child exited with parent stdin open.'
    Assert ($case.Process.ExitCode -eq 0) 'Bridge failed to pass through child exit code.'
    $results += 'early child exit closes bridge'
} finally { $case.Process.Dispose() }

Write-Output 'RUN concurrent-same-config'
$case = Start-Case 'concurrent-same-config'
try {
    1..3 | ForEach-Object { [void](Read-Line $case.Process.StandardOutput) }
    $client = Connect-Pipe $case.Pipe
    try {
        Assert ((Command $client @{ command='snapshot' }).pending.Count -eq 1) 'First bridge request missing.'
        $second = Start-SameCase $case
        try {
            1..3 | ForEach-Object { [void](Read-Line $second.Process.StandardOutput) }
            $second.Process.StandardInput.WriteLine('{"id":42,"result":{"answers":{}}}')
            Assert ((Read-Line $second.Process.StandardOutput).params.message.id -eq 42) 'Second instance native passthrough failed.'
            Assert ((Command $client @{ command='snapshot' }).pending.Count -eq 1) 'Second instance mixed into first pipe.'
            $results += 'same-config concurrent fallback and child CLI path'
        } finally { Close-Case $second }
    } finally { $client.Pipe.Dispose() }
} finally { Close-Case $case }

$results | ForEach-Object { Write-Output ('PASS ' + $_) }
Write-Output ('Test files: ' + $tempRoot)
