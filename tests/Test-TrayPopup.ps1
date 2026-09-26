$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
if (-not ('CodexDual.TrayPopup' -as [type])) {
    Add-Type -Path "$PSScriptRoot\..\src\TrayPopup.cs" -ReferencedAssemblies System.Windows.Forms,System.Drawing
}
if (-not ('TrayPopupTestSlowWork' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Threading;
public static class TrayPopupTestSlowWork {
    public static void Start(ManualResetEvent done) {
        ThreadPool.QueueUserWorkItem(delegate(object state) {
            Thread.Sleep(400);
            ((ManualResetEvent)state).Set();
        }, done);
    }
}
'@
}

$script:passed = 0
$script:clicks = 0
$script:nestedClicks = 0
$script:ticks = 0
function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Output "PASS: $Message"
}
function Pump([int]$Milliseconds) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $Milliseconds) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 5
    }
}
function Key($Form, [Windows.Forms.Keys]$Code) {
    $flags = [Reflection.BindingFlags]'Instance,NonPublic'
    $method = [Windows.Forms.Form].GetMethod('ProcessCmdKey', $flags)
    $message = [Windows.Forms.Message]::Create($Form.Handle, 0x100, [IntPtr][int]$Code, [IntPtr]::Zero)
    return [bool]$method.Invoke($Form, @($message, $Code))
}
function Bounds-Inside([Drawing.Rectangle]$Box, [Drawing.Rectangle]$Area) {
    return $Box.Width -gt 0 -and $Box.Height -gt 0 -and $Area.Contains($Box)
}

$work = New-Object Drawing.Rectangle(0,0,1920,1080)
$size = New-Object Drawing.Size(360,500)
$corners = @(
    @(0,0), @(1919,0), @(0,1079), @(1919,1079)
)
foreach ($corner in $corners) {
    $anchor = New-Object Drawing.Point($corner[0],$corner[1])
    $bounds = [CodexDual.TrayPopup]::CalculateBounds($anchor,$size,$work)
    Check (Bounds-Inside $bounds $work) "Corner anchor $anchor stays within work area"
}
$bottomRight = [CodexDual.TrayPopup]::CalculateBounds((New-Object Drawing.Point(1919,1079)),$size,$work)
Check ($bottomRight.Right -lt 1919 -and $bottomRight.Bottom -lt 1079) 'Bottom-right anchor flips left and up'
$negative = New-Object Drawing.Rectangle(-1920,-120,1920,1080)
$negativeBox = [CodexDual.TrayPopup]::CalculateBounds((New-Object Drawing.Point(-1919,-119)),$size,$negative)
Check (Bounds-Inside $negativeBox $negative) 'Negative-coordinate monitor stays within its work area'
$small = New-Object Drawing.Rectangle(100,100,250,180)
$smallBox = [CodexDual.TrayPopup]::CalculateBounds((New-Object Drawing.Point(348,278)),$size,$small)
Check ((Bounds-Inside $smallBox $small) -and $smallBox.Size -eq (New-Object Drawing.Size(234,164))) 'Small work area constrains popup dimensions'

$popup = $null
$other = $null
$timer = $null
$signal = $null
try {
    $popup = New-Object CodexDual.TrayPopup
    $popup.Size = $size
    $first = New-Object Windows.Forms.Button
    $first.Text = 'First'
    $first.Location = New-Object Drawing.Point(12,12)
    $first.TabIndex = 0
    $first.Add_Click({ $script:clicks++ })
    $disabled = New-Object Windows.Forms.Button
    $disabled.Enabled = $false
    $disabled.TabIndex = 1
    $second = New-Object Windows.Forms.Button
    $second.Text = 'Second'
    $second.Location = New-Object Drawing.Point(12,48)
    $second.TabIndex = 2
    $panel = New-Object Windows.Forms.Panel
    $panel.Location = New-Object Drawing.Point(12,85)
    $panel.Size = New-Object Drawing.Size(180,50)
    $panel.TabIndex = 3
    $nested = New-Object Windows.Forms.Button
    $nested.Text = 'Nested'
    $nested.TabIndex = 0
    $nested.Add_Click({ $script:nestedClicks++ })
    $panel.Controls.Add($nested)
    $popup.Controls.AddRange(@($first,$disabled,$second,$panel))

    $screen = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $popup.ShowAt([Windows.Forms.Cursor]::Position,$screen)
    Pump 60
    Check ($popup.Visible -and (Bounds-Inside $popup.Bounds $screen)) 'ShowAt opens inside the current work area'
    $handle = $popup.Handle
    $openForms = [Windows.Forms.Application]::OpenForms.Count
    $popup.ShowAt([Windows.Forms.Cursor]::Position,$screen)
    Pump 20
    Check ($popup.Handle -eq $handle -and [Windows.Forms.Application]::OpenForms.Count -eq $openForms) 'Repeated ShowAt reuses one native window'
    $popup.ShowAt((New-Object Drawing.Point(348,278)),$small)
    Check ($popup.Size -eq (New-Object Drawing.Size(234,164))) 'ShowAt constrains popup on small work area'
    $popup.ShowAt([Windows.Forms.Cursor]::Position,$screen)
    Check ($popup.Size -eq $size) 'ShowAt restores requested size after small work area'
    $popup.ActiveControl = $first
    Check ((Key $popup ([Windows.Forms.Keys]::Down)) -and $popup.ActiveControl -eq $second) 'Down skips disabled controls'
    Check ((Key $popup ([Windows.Forms.Keys]::Up)) -and $popup.ActiveControl -eq $first) 'Up returns to previous button'
    Check ((Key $popup ([Windows.Forms.Keys]::Tab)) -and $popup.ActiveControl -eq $second) 'Tab advances to next enabled button'
    Check ((Key $popup ([Windows.Forms.Keys]::Shift -bor [Windows.Forms.Keys]::Tab)) -and $popup.ActiveControl -eq $first) 'Shift+Tab returns to previous button'
    $popup.ActiveControl = $second
    Check ((Key $popup ([Windows.Forms.Keys]::Down)) -and $nested.Focused) 'Down enters button within nested panel'
    Check ((Key $popup ([Windows.Forms.Keys]::Enter)) -and $script:nestedClicks -eq 1) 'Enter invokes nested button'
    Check ((Key $popup ([Windows.Forms.Keys]::Up)) -and $popup.ActiveControl -eq $second) 'Up returns from nested panel button'
    $popup.ActiveControl = $first
    Check ((Key $popup ([Windows.Forms.Keys]::Enter)) -and $script:clicks -eq 1) 'Enter invokes the focused button once'
    $popup.ActiveControl = $null
    Check ((Key $popup ([Windows.Forms.Keys]::Up)) -and $nested.Focused) 'Up without focused button selects last button'
    $popup.ActiveControl = $null
    Check ((Key $popup ([Windows.Forms.Keys]::Shift -bor [Windows.Forms.Keys]::Tab)) -and $nested.Focused) 'Shift+Tab without focused button selects last button'
    Check ((Key $popup ([Windows.Forms.Keys]::Escape)) -and -not $popup.Visible) 'Escape hides the popup'
    $popup.ShowAt([Windows.Forms.Cursor]::Position,$screen)
    Check ($popup.Visible -and $popup.Handle -eq $handle) 'Hidden popup reopens with same handle'
    $popup.Close()
    Check (-not $popup.Visible -and -not $popup.IsDisposed) 'User Close hides without disposing popup'
    $popup.ShowAt([Windows.Forms.Cursor]::Position,$screen)
    Check ($popup.Visible -and $popup.Handle -eq $handle) 'Popup reopens with same handle after Close'

    $other = New-Object Windows.Forms.Form
    $other.StartPosition = 'Manual'
    $other.Location = New-Object Drawing.Point(20,20)
    $other.ShowInTaskbar = $false
    $other.Show()
    $other.Activate()
    Pump 80
    Check (-not $popup.Visible) 'Activation of another form hides popup'
    $other.Hide()

    $popup.ShowAt([Windows.Forms.Cursor]::Position,$screen)
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 30
    $timer.Add_Tick({ $script:ticks++ })
    $timer.Start()
    $signal = New-Object Threading.ManualResetEvent($false)
    [TrayPopupTestSlowWork]::Start($signal)
    Pump 450
    Check ($signal.WaitOne(0) -and $script:ticks -ge 7) 'UI timer keeps ticking during background simulated slow work'
    $timer.Stop()

    $popup.Dispose()
    Check ($popup.IsDisposed -and -not $popup.Visible) 'Dispose closes popup and releases its form'
} finally {
    if ($timer) { $timer.Stop(); $timer.Dispose() }
    if ($signal) { $signal.Dispose() }
    if ($popup) { $popup.Dispose() }
    if ($other) { $other.Dispose() }
}
if ($script:passed -ne 28) { throw "Tray popup checks were skipped: $script:passed" }
Write-Output "PASSED: $script:passed tray popup checks"
