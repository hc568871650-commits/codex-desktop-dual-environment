param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop'){throw '请使用系统 Windows PowerShell 5.1 编译。'}
$root=Split-Path $PSScriptRoot -Parent
$output=[IO.Path]::GetFullPath($Destination)
if(Test-Path -LiteralPath $output){throw '目标 EXE 已存在，不覆盖。'}
[void][IO.Directory]::CreateDirectory((Split-Path $output -Parent))
$compiler=New-Object Microsoft.CSharp.CSharpCodeProvider
$parameters=New-Object CodeDom.Compiler.CompilerParameters
$parameters.GenerateExecutable=$true;$parameters.OutputAssembly=$output
$parameters.CompilerOptions='/target:winexe /platform:x64 /win32icon:"'+(Join-Path $root 'assets\controller.ico')+'"'
foreach($assembly in @('System.dll','System.Core.dll','System.Windows.Forms.dll',[Management.Automation.PowerShell].Assembly.Location)){[void]$parameters.ReferencedAssemblies.Add($assembly)}
try{$result=$compiler.CompileAssemblyFromFile($parameters,(Join-Path $root 'src\ControllerHost.cs'));if($result.Errors.HasErrors){throw ($result.Errors|Out-String)}}finally{$compiler.Dispose()}
Write-Output $output
