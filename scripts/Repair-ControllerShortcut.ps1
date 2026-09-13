param(
    [string]$InstallDirectory=(Split-Path $PSScriptRoot -Parent),
    [string]$ShortcutDirectory=[Environment]::GetFolderPath('Desktop')
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
$root=Get-FullDirectory $InstallDirectory
$directory=Get-FullDirectory $ShortcutDirectory
$manifestPath=Join-Path $root 'install-manifest.json'
$configPath=Join-Path $root 'instances.local.json'
$hostPath=Join-Path $root 'CodexDualController.exe'
foreach($path in @($root,$directory,$manifestPath,$hostPath)){Assert-NoReparsePoint $path}
[void](Read-ControllerConfig $configPath)
if(-not (Test-Path -LiteralPath $hostPath -PathType Leaf)){throw 'Controller EXE is missing.'}
$manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
if($manifest.schema -ne 1 -or -not (Test-SamePath $manifest.root $root)){throw 'Installation manifest does not match the target.'}
$linkPath=Join-Path $directory 'Codex Dual Controller.lnk'
Assert-NoReparsePoint $linkPath
$shell=New-Object -ComObject WScript.Shell
if(Test-Path -LiteralPath $linkPath){
    $existing=$shell.CreateShortcut($linkPath)
    if(-not (Test-SamePath $existing.TargetPath $hostPath) -or $existing.Arguments -ne ''){throw 'A different shortcut already exists; it has been preserved.'}
    # Preserve existing ownership and hashes; do not adopt a user-created/edited link.
    Write-Output $linkPath
    return
}else{
    [void][IO.Directory]::CreateDirectory($directory)
    $link=$shell.CreateShortcut($linkPath)
    $link.TargetPath=$hostPath;$link.Arguments='';$link.WorkingDirectory=$root
    $link.IconLocation=Join-Path $root 'assets\controller.ico';$link.Description='Codex dual environment control panel'
    $link.Save()
}
$entries=@($manifest.shortcuts|Where-Object {-not (Test-SamePath $_.path $linkPath)})
$manifest.shortcuts=$entries+@(@{path=$linkPath;sha256=(Get-FileHash -LiteralPath $linkPath).Hash})
Write-AtomicText $manifestPath ($manifest|ConvertTo-Json -Depth 8)
Write-Output $linkPath
