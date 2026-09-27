param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use Windows PowerShell 5.1.' }
$output = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $output) { throw 'Fake EXE exists; choose a new path.' }
[void][IO.Directory]::CreateDirectory((Split-Path $output -Parent))
$compiler = New-Object Microsoft.CSharp.CSharpCodeProvider
$options = New-Object CodeDom.Compiler.CompilerParameters
$options.GenerateExecutable = $true
$options.OutputAssembly = $output
foreach ($assembly in @('System.dll','System.Web.Extensions.dll')) {
    [void]$options.ReferencedAssemblies.Add($assembly)
}
try {
    $result = $compiler.CompileAssemblyFromFile($options, (Join-Path $PSScriptRoot 'FakeAppServer.cs'))
    if ($result.Errors.HasErrors) { throw ($result.Errors | Out-String) }
} finally { $compiler.Dispose() }
Write-Output $output
