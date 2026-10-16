[CmdletBinding()]
param([string]$Destination='')
$ErrorActionPreference='Stop'
if(-not $Destination){$Destination=Join-Path $PSScriptRoot 'bin\RealCliQuestionFixture.exe'}
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1.'}
$source=Join-Path (Split-Path $PSScriptRoot -Parent) 'notification-bridge\tests\RealCliQuestionFixture.cs'
$text=[IO.File]::ReadAllText($source)
$anchor='static int Main(string[] args) {'
if(($text.Split(@($anchor),[StringSplitOptions]::None)).Length -ne 2){throw 'Fixture entry point changed.'}
$text=$text.Replace($anchor,$anchor+"`n  FixtureContainment.Initialize();")
[void][IO.Directory]::CreateDirectory((Split-Path $Destination -Parent))
$compiler=New-Object Microsoft.CSharp.CSharpCodeProvider
$options=New-Object CodeDom.Compiler.CompilerParameters
$options.GenerateExecutable=$true;$options.OutputAssembly=$Destination;$options.CompilerOptions='/target:exe /platform:x64'
foreach($assembly in @('System.dll','System.Core.dll','System.Web.Extensions.dll')){[void]$options.ReferencedAssemblies.Add($assembly)}
try {
 $build=$compiler.CompileAssemblyFromSource($options,[string[]]@($text,[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FixtureContainment.cs'))))
 if($build.Errors.HasErrors){throw ($build.Errors|Out-String)}
}finally{$compiler.Dispose()}
Get-FileHash -LiteralPath $Destination -Algorithm SHA256
