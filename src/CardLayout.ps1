# Cards arrive oldest first. Only actual, non-disposed cards occupy space.
function Set-NotificationCardLayout($Cards,[Drawing.Rectangle]$WorkingArea) {
    $active=@($Cards|Where-Object {-not $_.IsDisposed})
    $bottom=$WorkingArea.Bottom-20
    for($index=$active.Count-1;$index -ge 0;$index--){
        $card=$active[$index]
        $x=[Math]::Max($WorkingArea.Left,$WorkingArea.Right-$card.Width-20)
        $y=[Math]::Max($WorkingArea.Top,$bottom-$card.Height)
        $card.Location=New-Object Drawing.Point($x,$y)
        $bottom=$y-12
    }
}
