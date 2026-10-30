param([string]$DotNet='dotnet',[string]$OutputDirectory='', [switch]$SkipTests, [switch]$SelfContained)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$version=Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw -Encoding UTF8|ConvertFrom-Json
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root ('dist\dotnet-'+$version.version)}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new output directory; existing output is never merged.'}
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
$env:MSBUILDDISABLENODEREUSE='1'
if(-not $SkipTests){
    & $DotNet run --project (Join-Path $root 'dotnet\CodexDual.Tests\CodexDual.Tests.csproj') -c Release --verbosity quiet
    if($LASTEXITCODE -ne 0){throw 'C# tests failed.'}
}
& $DotNet publish (Join-Path $root 'dotnet\CodexDual.App\CodexDual.App.csproj') -c Release -r win-x64 --self-contained $SelfContained.ToString().ToLowerInvariant() -p:Version=$($version.version) -p:DebugType=None -p:DebugSymbols=false -o $OutputDirectory --nologo -v quiet -m:1 -p:UseSharedCompilation=false
if($LASTEXITCODE -ne 0){throw 'C# publish failed.'}
foreach($name in @('Controller.cmd','Configure.cmd','Start.cmd')){[IO.File]::Copy((Join-Path $root ('dotnet\Launchers\'+$name)),(Join-Path $OutputDirectory $name),$true)}
[IO.File]::Copy((Join-Path $root 'version.json'),(Join-Path $OutputDirectory 'version.json'),$false)
$files=@(Get-ChildItem -LiteralPath $OutputDirectory -File -Recurse | Where-Object {$_.Name -ne 'dotnet-manifest.json'} | ForEach-Object {@{path=$_.FullName.Substring($OutputDirectory.Length+1);sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
@{schema=1;version=$version.version;selfContained=[bool]$SelfContained;files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $OutputDirectory 'dotnet-manifest.json') -Encoding UTF8
Write-Output $OutputDirectory
