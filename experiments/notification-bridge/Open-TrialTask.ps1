param([string]$TrialDirectory=$PSScriptRoot,[Parameter(Mandatory=$true)][string]$ThreadId,[switch]$PackageContext)
. "$PSScriptRoot\Trial.Common.ps1"
$m=Read-BridgeTrial $TrialDirectory
$record=Get-Content -LiteralPath (Assert-PlainTrialPath (Join-Path $m.root 'desktop-process.json')) -Raw -Encoding UTF8|ConvertFrom-Json
$p=Get-Process -Id $record.pid -ErrorAction Stop
try{
    if($p.StartTime.ToUniversalTime().ToString('o') -ne $record.startedUtc -or $p.Path -ne $m.desktopExe -or $record.profile -ne $m.profile -or $record.apiHome -ne $m.apiHome){throw 'The trial desktop identity changed; refusing to open another instance.'}
    $native=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.Id)
    $pattern='--user-data-dir=(?:"'+[regex]::Escape($m.profile)+'"|'+[regex]::Escape($m.profile)+'(?:\s|$))'
    if($native.CommandLine -notmatch $pattern){throw 'The process does not belong to this isolated profile.'}
}finally{$p.Dispose()}
$info=New-TrialDesktopStartInfo $m -ThreadId $ThreadId
if(-not $PackageContext -and $m.desktopExe -like '*\WindowsApps\*'){
    $package=@(Get-AppxPackage -Name OpenAI.Codex|Where-Object {$m.desktopExe.StartsWith($_.InstallLocation+'\',[StringComparison]::OrdinalIgnoreCase)})
    if($package.Count -ne 1){throw 'Could not identify the trial desktop package.'}
    Add-Type -Path "$PSScriptRoot\TrialAppx.cs"
    $arguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -TrialDirectory "'+$m.root+'" -ThreadId "'+([guid]$ThreadId).ToString()+'" -PackageContext'
    [void][CodexBridgeTrial.AppxLauncher]::Start(($package[0].PackageFamilyName+'!App'),"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe",$arguments)
}else{
    $secondary=[Diagnostics.Process]::Start($info)
    try{if(-not $secondary.WaitForExit(8000)){throw 'Trial task activation has not completed. No repeated launch will be attempted.'}}finally{$secondary.Dispose()}
}
Write-Output 'Requested the task in the verified trial profile. Confirm the displayed task in Codex.'
