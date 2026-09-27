Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Assert-PlainTrialPath([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    $part=$full
    while($part){
        if((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Trial paths must not traverse a reparse point.'}
        $parent=[IO.Path]::GetDirectoryName($part)
        if($parent -eq $part){break};$part=$parent
    }
    return $full
}
function Write-TrialJson([string]$Path,$Value) {
    $path=Assert-PlainTrialPath $Path
    $temp=$path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
    if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
}
function Read-BridgeTrial([string]$Directory) {
    $root=Assert-PlainTrialPath $Directory
    $manifestPath=Assert-PlainTrialPath (Join-Path $root 'trial.json')
    $m=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($m.schema -ne 1 -or $m.kind -ne 'isolated-api-bridge-trial' -or $m.id -notmatch '^[a-f0-9]{32}$' -or $m.root -ne $root){throw 'Not a matching isolated bridge trial.'}
    foreach($entry in @(@('apiHome','CodexHome'),@('profile','DesktopProfile'),@('projects','Projects'))){
        $expected=Join-Path $root $entry[1]
        if($m.($entry[0]) -ne $expected){throw 'Trial directory binding was changed.'}
        [void](Assert-PlainTrialPath $expected)
    }
    [void](Assert-PlainTrialPath (Join-Path $root 'DISABLED'))
    return $m
}
function Assert-TrialBinary([string]$Path,[string]$Hash) {
    [void](Assert-PlainTrialPath $Path)
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash){throw 'A trial executable changed or is missing. Rebuild a new trial; do not reuse a changed runtime.'}
}
function New-TrialDesktopStartInfo($Manifest,[switch]$WithoutBridge,[string]$ThreadId) {
    $root=$Manifest.root
    Assert-TrialBinary $Manifest.desktopExe $Manifest.desktopHash
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Manifest.desktopExe;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WorkingDirectory=$Manifest.projects
    foreach($name in @($info.EnvironmentVariables.Keys)){
        if($name -match '^(CODEX_|OPENAI_|CHATGPT_|ELECTRON_)' -or $name -match '(?i)(API_KEY|ACCESS_TOKEN|AUTH_TOKEN|SECRET_KEY)$' -or $name -in @('CUSTOM_API_KEY','NODE_OPTIONS')){$info.EnvironmentVariables.Remove($name)}
    }
    $info.EnvironmentVariables['CODEX_HOME']=$Manifest.apiHome
    $info.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH']=$Manifest.profile
    $info.Arguments='--user-data-dir="'+$Manifest.profile+'"'
    if($ThreadId){
        $thread=[guid]::Empty
        if(-not [guid]::TryParseExact($ThreadId,'D',[ref]$thread)){throw 'Invalid task ID.'}
        $info.Arguments+=' "codex://threads/'+$thread.ToString()+'"'
    }
    if(-not $WithoutBridge -and -not (Test-Path -LiteralPath (Join-Path $root 'DISABLED'))){
        $proxy=Join-Path $root 'BridgeProxy.exe';Assert-TrialBinary $proxy $Manifest.proxyHash
        Assert-TrialBinary $Manifest.realCli $Manifest.realCliHash
        $info.EnvironmentVariables['CODEX_CLI_PATH']=$proxy
    }
    return $info
}
