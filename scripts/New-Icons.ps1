$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$dest=Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
[void][IO.Directory]::CreateDirectory($dest)
foreach($item in @(@('controller','D','#324358'),@('official','O','#15805D'),@('api','A','#2865CD'))){
    $bitmap=New-Object Drawing.Bitmap(64,64);$graphics=[Drawing.Graphics]::FromImage($bitmap)
    $brush=New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml($item[2]));$font=New-Object Drawing.Font('Segoe UI',34,[Drawing.FontStyle]::Bold)
    try{
        $graphics.Clear([Drawing.Color]::Transparent);$graphics.FillEllipse($brush,2,2,60,60);$graphics.DrawString($item[1],$font,[Drawing.Brushes]::White,10,3)
        $png=New-Object IO.MemoryStream;$bitmap.Save($png,[Drawing.Imaging.ImageFormat]::Png);$bytes=$png.ToArray();$png.Dispose()
        $stream=[IO.File]::Create((Join-Path $dest ($item[0]+'.ico')));$writer=New-Object IO.BinaryWriter($stream)
        try{$writer.Write([UInt16]0);$writer.Write([UInt16]1);$writer.Write([UInt16]1);$writer.Write([byte]64);$writer.Write([byte]64);$writer.Write([byte]0);$writer.Write([byte]0);$writer.Write([UInt16]1);$writer.Write([UInt16]32);$writer.Write([UInt32]$bytes.Length);$writer.Write([UInt32]22);$writer.Write($bytes)}finally{$writer.Dispose()}
    }finally{$graphics.Dispose();$bitmap.Dispose();$brush.Dispose();$font.Dispose()}
}
