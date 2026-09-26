$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
if (-not ('CodexDual.TrayClick' -as [type])) {
    Add-Type -Path "$PSScriptRoot\..\src\TrayClick.cs" -ReferencedAssemblies System.Windows.Forms
}

$script:passed = 0
$script:events = New-Object 'System.Collections.Generic.List[string]'
function Check($Value, [string]$Message) {
    if (-not $Value) { throw "FAIL: $Message (events: $($script:events -join ','))" }
    $script:passed++
    Write-Output "PASS: $Message"
}
function Pump([int]$Milliseconds) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $Milliseconds) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 5
    }
    [Windows.Forms.Application]::DoEvents()
}
function Reset-Events { $script:events.Clear() }

$form = New-Object Windows.Forms.Form
$form.StartPosition = 'Manual'
$form.Location = New-Object Drawing.Point(-32000,-32000)
$form.ShowInTaskbar = $false
$form.Show()
$click = $null
try {
    $default = New-Object CodexDual.TrayClick
    try {
        Check ($default.Interval -ge [Math]::Max([Windows.Forms.SystemInformation]::DoubleClickTime,550)) 'Default waits at least the system double-click interval and 550ms'
    } finally { $default.Dispose() }

    $click = New-Object CodexDual.TrayClick(180)
    $click.add_SingleClick({ [void]$script:events.Add('api') })
    $click.add_DoubleClick({ [void]$script:events.Add('panel') })
    $click.HandleMouseDown([Windows.Forms.MouseButtons]::Left)
    Pump 100
    Check ($script:events.Count -eq 0) 'A single click does not act before its deadline'
    Pump 130
    Check ($script:events.Count -eq 1 -and $script:events[0] -eq 'api') 'A single click fires after the deadline'

    Reset-Events
    $click.HandleMouseDown([Windows.Forms.MouseButtons]::Left)
    Pump 160
    $click.HandleMouseDown([Windows.Forms.MouseButtons]::Left)
    Check ($script:events.Count -eq 1 -and $script:events[0] -eq 'panel') 'Near-deadline second click opens only the panel'
    Pump 230
    Check ($script:events.Count -eq 1) 'Native double-click follow-up does not leave a pending single click'

    Reset-Events
    $click.HandleMouseDown([Windows.Forms.MouseButtons]::Left)
    $click.HandleMouseDown([Windows.Forms.MouseButtons]::Left)
    $click.HandleMouseDown([Windows.Forms.MouseButtons]::Left)
    Pump 230
    Check ($script:events.Count -eq 2 -and $script:events[0] -eq 'panel' -and $script:events[1] -eq 'api') 'Three mouse downs produce double then single'

    Reset-Events
    $click.HandleMouseDown([Windows.Forms.MouseButtons]::Left)
    $click.HandleMouseDown([Windows.Forms.MouseButtons]::Right)
    Pump 230
    Check ($script:events.Count -eq 0) 'Right mouse down cancels pending left action'

    Reset-Events
    $click.HandleMouseDown([Windows.Forms.MouseButtons]::Left)
    Start-Sleep -Milliseconds 200
    $click.HandleMouseDown([Windows.Forms.MouseButtons]::Left)
    Check ($script:events.Count -eq 1 -and $script:events[0] -eq 'api') 'Second click beyond deadline flushes first single even if timer was delayed'
    Pump 230
    Check ($script:events.Count -eq 2 -and $script:events[1] -eq 'api') 'Slow second click produces its own single'

    Reset-Events
    $click.HandleMouseDown([Windows.Forms.MouseButtons]::Left)
    $click.Dispose()
    Pump 230
    $click.HandleMouseDown([Windows.Forms.MouseButtons]::Left)
    $click.Dispose()
    Check ($script:events.Count -eq 0) 'Dispose cancels queued action and ignores subsequent input'
} finally {
    if ($click) { $click.Dispose() }
    $form.Dispose()
}
if ($script:passed -ne 10) { throw 'Tray click checks were skipped.' }
Write-Output "PASSED: $script:passed tray click checks"
