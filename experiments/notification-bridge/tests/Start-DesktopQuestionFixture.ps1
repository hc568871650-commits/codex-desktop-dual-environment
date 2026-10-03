param([Parameter(Mandatory=$true)][string]$OutputDirectory,[int]$Port=0,[switch]$BuildOnly)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1.'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $OutputDirectory){throw 'Choose a fresh isolated fixture directory.'}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$compiler=New-Object Microsoft.CSharp.CSharpCodeProvider
$options=New-Object CodeDom.Compiler.CompilerParameters
$options.GenerateExecutable=$true
$options.OutputAssembly=Join-Path $OutputDirectory 'DesktopQuestionFixture.exe'
$options.CompilerOptions='/target:exe /platform:x64'
foreach($assembly in @('System.dll','System.Core.dll','System.Web.Extensions.dll')){[void]$options.ReferencedAssemblies.Add($assembly)}
try{$build=$compiler.CompileAssemblyFromFile($options,(Join-Path $PSScriptRoot 'DesktopQuestionFixture.cs'));if($build.Errors.HasErrors){throw ($build.Errors|Out-String)}}finally{$compiler.Dispose()}
if($BuildOnly){Write-Output $options.OutputAssembly;return}
& $options.OutputAssembly $OutputDirectory $Port
if($LASTEXITCODE -ne 0){throw "Desktop fixture failed: $LASTEXITCODE"}
