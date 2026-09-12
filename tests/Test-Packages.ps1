param([Parameter(Mandatory=$true)][string]$FullArchive,[Parameter(Mandatory=$true)][string]$UpgradeArchive,[Parameter(Mandatory=$true)][string]$BaselineArchive)
$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath("$PSScriptRoot\..")
$root=Join-Path $source ('test-results\packages-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:passed=0
function Check($Value,$Message){if(-not $Value){throw "FAIL: $Message"};$script:passed++;Write-Output "PASS: $Message"}
foreach($archive in @($FullArchive,$UpgradeArchive)){
    $zip=[IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($archive))
    try{
        foreach($entry in $zip.Entries){
            $relative=$entry.FullName.Replace('/','\')
            if($relative.EndsWith('\')){continue}
            if($relative -match '(^|\\)(test-results|dist|state|runtime|Credentials|sessions)(\\|$)' -or $relative -match '\.local\.json$|\.dpapi$|(^|\\)auth\.json$|\.db$'){throw 'Archive contains runtime data: '+$relative}
            $expected=[IO.Path]::GetFullPath((Join-Path $source $relative))
            if(-not $expected.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Archive path escapes source'}
            $stream=$entry.Open();$hash=[Security.Cryptography.SHA256]::Create()
            try{$actual=[BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','')}finally{$hash.Dispose();$stream.Dispose()}
            if(-not (Test-Path -LiteralPath $expected) -or (Get-FileHash -LiteralPath $expected).Hash -ne $actual){throw 'Archive differs from validated source: '+$relative}
        }
        Check $true ('Archive matches source and excludes runtime data: '+[IO.Path]::GetFileName($archive))
    }finally{$zip.Dispose()}
}
$full=Join-Path $root 'Full';$upgrade=Join-Path $root 'Upgrade';$baseline=Join-Path $root 'Baseline'
Expand-Archive -LiteralPath $FullArchive -DestinationPath $full
Expand-Archive -LiteralPath $UpgradeArchive -DestinationPath $upgrade
Expand-Archive -LiteralPath $BaselineArchive -DestinationPath $baseline
$install=Join-Path $root 'OldInstall';$data=Join-Path $root 'OldData';$official=Join-Path $root 'Official'
$fake=ConvertTo-SecureString 'fixture-package-key' -AsPlainText -Force
& "$baseline\scripts\Install.ps1" -InstallDirectory $install -DataDirectory $data -OfficialHome $official -Executable "$env:SystemRoot\System32\notepad.exe" -BaseUrl 'https://example.com/v1' -Model 'fixture-model' -ApiKey $fake -NoShortcuts
Check ((Get-Content "$install\version.json" -Raw|ConvertFrom-Json).version -eq '0.2.0') 'Baseline comes from actual 0.2.0 package'
$protected=@("$install\instances.local.json","$official\config.toml","$data\API\CodexHome\config.toml","$data\API\CodexHome\auth.json","$data\API\Credentials\api-key.dpapi")
$hashes=@{};foreach($path in $protected){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
# Load upgrade functions in a fresh process: .NET types from the old package must
# not mask a missing assembly/source in the new package.
$driver=Join-Path $root 'upgrade-driver.ps1'
$driverText=@'
param([string]$Upgrade,[string]$Target,[string]$ReportPath)
$ErrorActionPreference='Stop'
. "$Upgrade\src\Upgrade.ps1"
$upgradeResult=Invoke-ControllerUpgrade -Source $Upgrade -Target $Target
$upgradeResult|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8
'@
[IO.File]::WriteAllText($driver,$driverText,(New-Object Text.UTF8Encoding($true)))
$resultPath=Join-Path $root 'upgrade-result.json'
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $driver -Upgrade $upgrade -Target $install -ReportPath $resultPath
Check ($LASTEXITCODE -eq 0 -and (Get-Content "$install\version.json" -Raw|ConvertFrom-Json).version -eq '0.3.0') 'Actual upgrade ZIP upgrades installed 0.2.0 to 0.3.0'
foreach($path in $protected){Check ((Get-FileHash -LiteralPath $path).Hash -eq $hashes[$path]) ('Packaged upgrade preserves '+[IO.Path]::GetFileName($path))}
Check (Test-Path -LiteralPath "$install\src\TomlConfig.cs") 'Packaged upgrade includes new runtime source'
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "$install\src\Controller.ps1" -ConfigPath "$install\instances.local.json" -Action panel -SmokeTest -ScreenshotPath "$root\upgraded-panel.png"
Check ($LASTEXITCODE -eq 0 -and (Test-Path "$root\upgraded-panel.png")) 'Installed upgraded package renders functioning panel'
$freshInstall=Join-Path $root 'FreshInstall';$freshData=Join-Path $root 'FreshData';$freshOfficial=Join-Path $root 'FreshOfficial'
$freshDriver=Join-Path $root 'fresh-driver.ps1'
$freshText=@'
param([string]$Source,[string]$Install,[string]$Data,[string]$Official)
$ErrorActionPreference='Stop'
$key=ConvertTo-SecureString 'fixture-fresh-key' -AsPlainText -Force
& "$Source\scripts\Install.ps1" -InstallDirectory $Install -DataDirectory $Data -OfficialHome $Official -Executable "$env:SystemRoot\System32\notepad.exe" -BaseUrl 'https://example.com/v1' -Model 'fixture-model' -ApiKey $key -NoShortcuts
'@
[IO.File]::WriteAllText($freshDriver,$freshText,(New-Object Text.UTF8Encoding($true)))
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $freshDriver -Source $full -Install $freshInstall -Data $freshData -Official $freshOfficial
Check ($LASTEXITCODE -eq 0 -and (Test-Path "$freshInstall\CodexDualController.exe")) 'Full ZIP installs and compiles without repository dependencies'
Write-Output "PASSED: $script:passed package checks. Output: $root"
