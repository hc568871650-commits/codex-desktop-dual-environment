# Shared by the API-only launcher and controller binding validation.
# Failure always leaves Desktop on its original native CLI path.
function Get-ValidatedApiQuestionBridge {
    param([string]$Directory,[string]$ApiHome,[string]$Profile,[string]$DesktopExecutable,[string]$InstanceId,[switch]$IgnoreDisabled)
    try {
        function Assert-BridgePlainPath([string]$Path) {
            if(-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')){throw 'Invalid bridge path'}
            $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
            $cursor=$full
            while($cursor){
                if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse bridge path'}
                $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
            }
            return $full
        }
        function Same-BridgePath([string]$First,[string]$Second){return (Assert-BridgePlainPath $First).Equals((Assert-BridgePlainPath $Second),[StringComparison]::OrdinalIgnoreCase)}
        $root=Assert-BridgePlainPath $Directory
        $manifestPath=Assert-BridgePlainPath (Join-Path $root 'binding.json')
        $configPath=Assert-BridgePlainPath (Join-Path $root 'bridge.config.json')
        $disabled=Assert-BridgePlainPath (Join-Path $root 'DISABLED')
        if(-not $IgnoreDisabled -and (Test-Path -LiteralPath $disabled)){return $null}
        if(Test-Path -LiteralPath (Join-Path $root 'trial.json')){return $null}
        $m=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
        $b=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($m.schema -ne 1 -or $m.kind -ne 'api-question-bridge-installation' -or $m.id -notmatch '^[a-f0-9]{32}$' -or $m.controllerInstanceId -notmatch '^[a-f0-9]{32}$' -or -not (Same-BridgePath $root $m.root)){return $null}
        if($m.userSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){return $null}
        if(-not (Same-BridgePath $m.apiHome $ApiHome) -or -not (Same-BridgePath $m.profile $Profile)){return $null}
        if($InstanceId -and $m.controllerInstanceId -ne $InstanceId){return $null}
        if($DesktopExecutable -and -not (Same-BridgePath $m.desktopExe $DesktopExecutable)){return $null}
        if($b.instanceId -ne ('api-live-'+$m.id) -or $b.pipeName -ne ('codex-api-questions-'+$m.id) -or $b.takeoverQuestions -isnot [bool] -or $b.takeoverQuestions -ne $true){return $null}
        if(-not (Same-BridgePath $b.apiHome $m.apiHome) -or -not (Same-BridgePath $b.realCli $m.realCli)){return $null}
        if((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne $m.configHash){return $null}
        $proxy=Assert-BridgePlainPath (Join-Path $root 'BridgeProxy.exe')
        foreach($entry in @(@($proxy,$m.proxyHash),@($m.realCli,$m.realCliHash),@($m.desktopExe,$m.desktopHash))){
            $path=Assert-BridgePlainPath $entry[0]
            if(-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry[1]){return $null}
        }
        return [pscustomobject]@{manifest=$m;config=$b;proxy=$proxy;directory=$root;disabled=$disabled}
    }catch{return $null}
}
