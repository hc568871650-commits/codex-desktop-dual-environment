param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1.'}
if(Test-Path -LiteralPath $Destination){throw 'Destination already exists.'}
Add-Type -Path (Join-Path $PSScriptRoot 'QuestionClient.cs') -ReferencedAssemblies System.dll,System.Core.dll,System.Drawing.dll,System.Windows.Forms.dll,System.Web.Extensions.dll -OutputAssembly $Destination -OutputType WindowsApplication
Write-Output $Destination
