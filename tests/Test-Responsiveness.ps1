$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
if (-not ('CodexDual.BackgroundWork' -as [type])) {
    Add-Type -Path "$PSScriptRoot\..\src\BackgroundWork.cs" -ReferencedAssemblies System.Management.Automation,System.Windows.Forms
}

$script:lines = New-Object 'System.Collections.Generic.List[string]'
$script:ticks = New-Object 'System.Collections.Generic.List[long]'
$resultDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\test-results'))
[void][IO.Directory]::CreateDirectory($resultDirectory)
$logPath = Join-Path $resultDirectory ('responsiveness-' + [Guid]::NewGuid().ToString('N') + '.log')
$worker = $null
$disposalWorker = $null
$timer = $null
$form = $null
$failed = $null

function Record([string]$Text) {
    [void]$script:lines.Add($Text)
    Write-Output $Text
}
function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Record "PASS: $Message"
}
function Expect-Error([scriptblock]$Action, [string]$Message) {
    $errorSeen = $false
    try { & $Action | Out-Null } catch { $errorSeen = $true }
    Check $errorSeen $Message
}
function Wait-Work($Target, [int]$TimeoutMilliseconds = 5000) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $Target.Completed -and $watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 5
    }
    [Windows.Forms.Application]::DoEvents()
    Check $Target.Completed 'Simulated work completes within timeout'
}

try {
    # A modeless, off-screen form gives the test a real WinForms message loop.
    $form = New-Object Windows.Forms.Form
    $form.StartPosition = 'Manual'
    $form.Location = New-Object Drawing.Point(-32000,-32000)
    $form.ShowInTaskbar = $false
    $form.Size = New-Object Drawing.Size(200,100)
    $form.Show()
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 40
    $timer.Add_Tick({ [void]$script:ticks.Add([DateTime]::UtcNow.Ticks) })
    $timer.Start()

    $worker = New-Object CodexDual.BackgroundWork
    $worker.Start('param($value) Start-Sleep -Milliseconds 800; $value', @('ready'))
    Check $worker.Busy 'Started work reports Busy'
    Expect-Error { $worker.Start('42', @()) } 'Busy rejects a second Start'
    Expect-Error { $worker.Take() } 'Take rejects unfinished work'
    Wait-Work $worker
    Check $worker.Busy 'Completed work stays Busy until Take'
    $output = $worker.Take()
    Check ($output.Count -eq 1 -and $output[0].ToString() -eq 'ready' -and -not $worker.Busy) 'Take returns result and frees worker for reuse'

    $gaps = @()
    for ($i = 1; $i -lt $script:ticks.Count; $i++) {
        $gaps += [Math]::Round(($script:ticks[$i] - $script:ticks[$i-1]) / 10000.0, 1)
    }
    Check ($gaps.Count -ge 8) 'UI timer continues ticking during slow work'
    $sorted = @($gaps | Sort-Object)
    $median = $sorted[[int][Math]::Floor(($sorted.Count - 1) / 2)]
    $p95 = $sorted[[int][Math]::Ceiling($sorted.Count * 0.95) - 1]
    $maximum = $sorted[-1]
    Record "TIMER: interval=40ms samples=$($gaps.Count) median=${median}ms p95=${p95}ms max=${maximum}ms"
    Check ($median -lt 150 -and $p95 -lt 250 -and $maximum -lt 300) 'UI timer remains responsive while worker sleeps'
    $timer.Stop()

    $worker.Start('param($value) $value', @(7))
    Wait-Work $worker
    $reused = $worker.Take()
    Record "REUSE: count=$($reused.Count) value=$([string]$reused)"
    if ($null -eq $reused -or $reused.Count -ne 1 -or [int]$reused[0] -ne 7) {
        $failed = 'Same worker did not produce a result on its second successful task'
        Record "FAIL: $failed"
    } else { Record 'PASS: Same worker handles a second successful task' }

    $worker.Start("throw 'simulated failure'", @())
    Wait-Work $worker
    $workFailure = $null
    try { $worker.Take() | Out-Null } catch { $workFailure = $_.Exception.Message }
    Record "WORK ERROR: $workFailure"
    Check ($null -ne $workFailure) 'Failed work is reported by Take'
    Check (-not $worker.Busy) 'Failed work releases Busy state'
    $worker.Start('23', @())
    Wait-Work $worker
    $recovered = $worker.Take()
    Record "RECOVERY: count=$($recovered.Count) value=$([string]$recovered)"
    if ($null -eq $recovered -or $recovered.Count -ne 1 -or [int]$recovered[0] -ne 23) {
        $failed = 'Same worker did not produce a result after failure'
        Record "FAIL: $failed"
    } else { Record 'PASS: Same worker succeeds after failure' }

    $disposalWorker = New-Object CodexDual.BackgroundWork
    $disposalWorker.Start('Start-Sleep -Milliseconds 2000', @())
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $disposalWorker.Dispose()
    $watch.Stop()
    Record "DISPOSE: pending-work elapsed=$($watch.ElapsedMilliseconds)ms"
    Check ($watch.ElapsedMilliseconds -lt 250) 'Dispose returns without waiting for pending work'
    $disposalWorker = $null
} catch {
    $failed = $_
    Record "FAIL: $($_.Exception.Message)"
} finally {
    if ($timer) { $timer.Stop(); $timer.Dispose() }
    if ($form) { $form.Close(); $form.Dispose() }
    if ($worker) { $worker.Dispose() }
    if ($disposalWorker) { $disposalWorker.Dispose() }
    [IO.File]::WriteAllLines($logPath, $script:lines.ToArray(), (New-Object Text.UTF8Encoding($true)))
    Write-Output "LOG: $logPath"
}
if ($failed) { throw $failed }
