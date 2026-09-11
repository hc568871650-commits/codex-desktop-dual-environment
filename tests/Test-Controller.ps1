$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('controller-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$config=Get-Content -LiteralPath "$PSScriptRoot\..\config\instances.example.json" -Raw | ConvertFrom-Json
$config.stateDirectory="$root\state"
foreach($i in $config.instances){$i.home="$root\$($i.role)\CodexHome";$i.profile="$root\$($i.role)\DesktopProfile";$i.projects="$root\$($i.role)\Projects";$i.projectless="$root\$($i.role)\Projectless";$i.executable="$env:SystemRoot\System32\notepad.exe";if($i.role -eq 'api'){$i.apiRoot="$root\api"}}
$path="$root\instances.local.json";Write-AtomicText $path ($config|ConvertTo-Json -Depth 5)
$controller=[IO.Path]::GetFullPath("$PSScriptRoot\..\src\Controller.ps1")
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $controller -ConfigPath $path -SmokeTest -ScreenshotPath "$root\menu.png"
if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath "$root\menu.png")){throw 'Tray smoke failed'}
Write-Output 'PASS: actual tray menu renders and disposes without exiting Codex'
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $controller -ConfigPath $path -Action panel -SmokeTest -ScreenshotPath "$root\panel.png"
if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath "$root\panel.png")){throw 'Panel smoke failed'}
Write-Output 'PASS: taskbar control panel renders and disposes'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex=New-Object Threading.Mutex($true,('Local\CodexDual.Controller.'+$sid))
try{
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe";$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.Arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+$controller+'" -ConfigPath "'+$path+'" -SmokeTest'
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $p=[Diagnostics.Process]::Start($psi);$out=$p.StandardOutput.ReadToEnd();$err=$p.StandardError.ReadToEnd();$p.WaitForExit()
    if($p.ExitCode -eq 0 -or -not $err.Contains('Controller already running')){throw 'Singleton enforcement failed'}
    $p.Dispose();Write-Output 'PASS: second controller process refused by per-user mutex'
}finally{$mutex.ReleaseMutex();$mutex.Dispose()}
Write-Output 'PASSED: 3 controller checks'
