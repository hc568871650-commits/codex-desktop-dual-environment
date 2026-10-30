param([string]$DotNet='dotnet',[string]$OutputDirectory='', [switch]$SkipTests)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root 'dist\dotnet-0.9.0-preview.2'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
$env:MSBUILDDISABLENODEREUSE='1'
if(-not $SkipTests){
    & $DotNet run --project (Join-Path $root 'dotnet\CodexDual.Tests\CodexDual.Tests.csproj') -c Release --verbosity quiet
    if($LASTEXITCODE -ne 0){throw 'C# tests failed.'}
}
& $DotNet publish (Join-Path $root 'dotnet\CodexDual.App\CodexDual.App.csproj') -c Release --self-contained false -o $OutputDirectory --nologo -v quiet -m:1 -p:UseSharedCompilation=false
if($LASTEXITCODE -ne 0){throw 'C# publish failed.'}
foreach($name in @('Controller.cmd','Configure.cmd','Start.cmd')){[IO.File]::Copy((Join-Path $root ('dotnet\Launchers\'+$name)),(Join-Path $OutputDirectory $name),$true)}
@{product='codex-desktop-dual-environment';version='0.9.0-preview.2';buildRevision='dotnet-ui-refresh';releaseChannel='local-preview';requires='Microsoft.WindowsDesktop.App 10.0 x64'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputDirectory 'version.json') -Encoding UTF8
$files=@(Get-ChildItem -LiteralPath $OutputDirectory -File -Recurse | Where-Object {$_.Name -ne 'dotnet-manifest.json'} | ForEach-Object {@{path=$_.FullName.Substring($OutputDirectory.Length+1);sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
@{schema=1;version='0.9.0-preview.2';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $OutputDirectory 'dotnet-manifest.json') -Encoding UTF8
Write-Output $OutputDirectory
