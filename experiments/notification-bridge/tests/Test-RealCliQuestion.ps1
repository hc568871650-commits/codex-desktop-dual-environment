param(
    [string]$CliPath='C:\Users\Administrator\AppData\Local\OpenAI\Codex\bin\faa963e871dd422c\codex.exe',
    [string]$OutputDirectory,
    [ValidateSet('mirror','sync','async')][string]$Mode='mirror',
    [switch]$CodeModeHost,
    [switch]$MultiConnection
)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1.'}
if(-not (Test-Path -LiteralPath $CliPath -PathType Leaf)){throw "Real CLI missing: $CliPath"}
$trial=Split-Path $PSScriptRoot -Parent
if(-not $OutputDirectory){$OutputDirectory=Join-Path ([IO.Path]::GetTempPath()) ('real-cli-question-'+[guid]::NewGuid().ToString('N'))}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $OutputDirectory){throw "Choose an empty output directory: $OutputDirectory"}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$bridge=Join-Path $OutputDirectory 'BridgeProxy.exe'
& (Join-Path $trial 'Build-Bridge.ps1') -Destination $bridge | Out-Null
$compiler=New-Object Microsoft.CSharp.CSharpCodeProvider
$options=New-Object CodeDom.Compiler.CompilerParameters
$options.GenerateExecutable=$true
$options.OutputAssembly=Join-Path $OutputDirectory 'RealCliQuestionFixture.exe'
$options.CompilerOptions='/target:exe /platform:x64'
foreach($assembly in @('System.dll','System.Core.dll','System.Web.Extensions.dll')){[void]$options.ReferencedAssemblies.Add($assembly)}
try{
    $build=$compiler.CompileAssemblyFromFile($options,(Join-Path $PSScriptRoot 'RealCliQuestionFixture.cs'))
    if($build.Errors.HasErrors){throw ($build.Errors|Out-String)}
}finally{$compiler.Dispose()}
& $options.OutputAssembly $CliPath $bridge $OutputDirectory $Mode ([string]$CodeModeHost.IsPresent) ([string]$MultiConnection.IsPresent)
if($LASTEXITCODE -ne 0){throw "Real CLI fixture failed. Evidence: $(Join-Path $OutputDirectory 'failure.json')"}
Write-Output "Evidence: $(Join-Path $OutputDirectory 'evidence.json')"
