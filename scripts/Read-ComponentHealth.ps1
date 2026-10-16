param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [string]$OutputPath
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. "$root\src\Instances.ps1"
. "$root\src\Diagnostics.ps1"
# No repair, service CLI, launcher, pipe connection or model request is invoked.
$config=Read-ControllerConfig $ConfigPath
$report=Get-ControllerDiagnostics $config $root
$text=ConvertTo-ControllerDiagnosticText $report
Write-Output $text
if($OutputPath){Export-ControllerDiagnostics $report $OutputPath}
