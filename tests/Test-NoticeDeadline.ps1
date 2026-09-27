$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -Path "$PSScriptRoot\..\src\CompletionCard.cs" -ReferencedAssemblies System.Windows.Forms,System.Drawing
$card=New-Object CodexDual.CompletionCard
$card.StartPosition='Manual';$card.ShowInTaskbar=$false;$card.Size=New-Object Drawing.Size(420,192)
$cursor=[Windows.Forms.Cursor]::Position
$card.Location=New-Object Drawing.Point(($cursor.X-100),($cursor.Y-80))
$card.SetDisplaySettings(5000,$false)
try{
    $card.Show();$card.Activate();[Windows.Forms.Application]::DoEvents()
    $hovered=$card.Bounds.Contains([Windows.Forms.Cursor]::Position);$focused=$card.ContainsFocus
    if(-not ($hovered -or $focused)){throw 'Test did not establish hover or focus'}
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while(-not $card.IsDisposed -and $timer.ElapsedMilliseconds -lt 6500){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}
    if(-not $card.IsDisposed -or $timer.ElapsedMilliseconds -lt 4700 -or $timer.ElapsedMilliseconds -gt 6000){throw ('Notice missed five-second deadline: '+$timer.ElapsedMilliseconds)}
    [pscustomobject]@{elapsedMilliseconds=$timer.ElapsedMilliseconds;initialHover=$hovered;initialFocus=$focused;closed=$true}|ConvertTo-Json -Compress
}finally{if(-not $card.IsDisposed){$card.Dispose()}}
