$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -Path "$PSScriptRoot\..\src\CompletionCard.cs" -ReferencedAssemblies System.Windows.Forms,System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NoticeShapeProbe {
 [DllImport("gdi32.dll")]static extern IntPtr CreateRectRgn(int l,int t,int r,int b);
 [DllImport("user32.dll")]static extern int GetWindowRgn(IntPtr window,IntPtr region);
 [DllImport("gdi32.dll")]static extern bool PtInRegion(IntPtr region,int x,int y);
 [DllImport("gdi32.dll")]static extern bool DeleteObject(IntPtr obj);
 public static bool Contains(IntPtr window,int x,int y){var r=CreateRectRgn(0,0,0,0);try{if(GetWindowRgn(window,r)==0)throw new Exception("Window has no clipping region");return PtInRegion(r,x,y);}finally{DeleteObject(r);}}
}
'@
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('notification-shape-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$card=New-Object CodexDual.CompletionCard;$card.StartPosition='Manual';$card.Location=New-Object Drawing.Point(-10000,-10000);$card.ShowInTaskbar=$false;$card.SetDisplaySettings(0,$false)
$passed=0
try{
 foreach($size in @(@(420,192),@(420,166),@(520,220))){
  $card.ClientSize=New-Object Drawing.Size($size[0],$size[1]);$card.Show();[Windows.Forms.Application]::DoEvents()
  foreach($point in @(@(0,0),@(($size[0]-1),0),@(0,($size[1]-1)),@(($size[0]-1),($size[1]-1)))){if([NoticeShapeProbe]::Contains($card.Handle,$point[0],$point[1])){throw 'Square corner remains in native window region'};$passed++}
  if(-not [NoticeShapeProbe]::Contains($card.Handle,20,20) -or -not [NoticeShapeProbe]::Contains($card.Handle,($size[0]/2),($size[1]/2))){throw 'Card interior was clipped'};$passed++
 }
 $card.ClientSize=New-Object Drawing.Size(420,192)
 $bitmap=New-Object Drawing.Bitmap(452,224);$content=New-Object Drawing.Bitmap(420,192);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{
  $graphics.Clear([Drawing.Color]::FromArgb(117,37,26));$card.DrawToBitmap($content,(New-Object Drawing.Rectangle(0,0,420,192)))
  $graphics.TranslateTransform(16,16);$graphics.SetClip($card.Region,[Drawing.Drawing2D.CombineMode]::Replace);$graphics.DrawImageUnscaled($content,0,0)
  $bitmap.Save((Join-Path $root 'rounded-card.png'))
 }finally{$graphics.Dispose();$content.Dispose();$bitmap.Dispose()}
}finally{$card.Dispose()}
Write-Output ('PASSED: '+$passed+' native window-region checks. Output: '+$root)
