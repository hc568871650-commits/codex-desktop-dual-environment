# Shared by the API-only launcher and read-only controller diagnostics.
# Only the compatibility wrapper exposes validated launch data; failure remains null.
function Get-ApiQuestionBridgeValidation {
    param([string]$Directory,[string]$ApiHome,[string]$Profile,[string]$DesktopExecutable,[string]$InstanceId,[switch]$IgnoreDisabled)
    $reason='PATH_UNSAFE'
    try {
        function Assert-BridgePlainPath([string]$Path) {
            if(-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')){throw 'Invalid bridge path'}
            $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
            $cursor=$full
            while($cursor){
                if((Test-Path -LiteralPath $cursor -ErrorAction Stop) -and ((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse bridge path'}
                $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
            }
            return $full
        }
        function Same-BridgePath([string]$First,[string]$Second){return (Assert-BridgePlainPath $First).Equals((Assert-BridgePlainPath $Second),[StringComparison]::OrdinalIgnoreCase)}
        function Read-BridgeJson([string]$Path) {
            if(-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop)){throw 'missing'}
            $stream=$null
            try {
                $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                if($stream.Length -gt 65536){throw 'oversize'}
                $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
                try{
                    $buffer=New-Object char[] 65537
                    $count=$reader.ReadBlock($buffer,0,$buffer.Length)
                    if($count -gt 65536){throw 'oversize'}
                    $raw=New-Object string($buffer,0,$count)
                }finally{$reader.Dispose();$stream=$null}
                if([string]::IsNullOrWhiteSpace($raw) -or $raw.IndexOf([char]0) -ge 0){throw 'invalid'}
                $value=ConvertFrom-Json -InputObject $raw -ErrorAction Stop
                if($null -eq $value -or $value -isnot [pscustomobject]){throw 'invalid'}
                return $value
            }finally{if($stream){$stream.Dispose()}}
        }
        $root=Assert-BridgePlainPath $Directory
        $manifestPath=Assert-BridgePlainPath (Join-Path $root 'binding.json')
        $configPath=Assert-BridgePlainPath (Join-Path $root 'bridge.config.json')
        $disabled=Assert-BridgePlainPath (Join-Path $root 'DISABLED')
        if(-not $IgnoreDisabled -and (Test-Path -LiteralPath $disabled)){ $reason='USER_DISABLED';throw 'disabled' }
        if(Test-Path -LiteralPath (Join-Path $root 'trial.json')){ $reason='TRIAL_CONFLICT';throw 'trial' }
        $reason='BINDING_UNREADABLE';$m=Read-BridgeJson $manifestPath
        $reason='CONFIG_UNREADABLE';$b=Read-BridgeJson $configPath
        $reason='BINDING_INVALID'
        if($m.schema -ne 1 -or $m.kind -ne 'api-question-bridge-installation' -or $m.id -notmatch '^[a-f0-9]{32}$' -or $m.controllerInstanceId -notmatch '^[a-f0-9]{32}$' -or -not (Same-BridgePath $root $m.root)){throw 'invalid'}
        $reason='IDENTITY_MISMATCH'
        if($m.userSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'identity'}
        if(-not (Same-BridgePath $m.apiHome $ApiHome) -or -not (Same-BridgePath $m.profile $Profile)){throw 'identity'}
        if($InstanceId -and $m.controllerInstanceId -ne $InstanceId){throw 'identity'}
        $reason='DESKTOP_CHANGED'
        if($DesktopExecutable -and -not (Same-BridgePath $m.desktopExe $DesktopExecutable)){throw 'desktop'}
        $reason='CONFIG_INVALID'
        if($b.instanceId -ne ('api-live-'+$m.id) -or $b.pipeName -ne ('codex-api-questions-'+$m.id) -or $b.takeoverQuestions -isnot [bool] -or $b.takeoverQuestions -ne $true){throw 'config'}
        if(-not (Same-BridgePath $b.apiHome $m.apiHome) -or -not (Same-BridgePath $b.realCli $m.realCli)){throw 'config'}
        $reason='CONFIG_HASH_CHANGED'
        if((Get-FileHash -LiteralPath $configPath -Algorithm SHA256 -ErrorAction Stop).Hash -ne $m.configHash){throw 'hash'}
        $proxy=Assert-BridgePlainPath (Join-Path $root 'BridgeProxy.exe')
        foreach($entry in @(@($proxy,$m.proxyHash,'PROXY'),@($m.realCli,$m.realCliHash,'CLI'),@($m.desktopExe,$m.desktopHash,'DESKTOP'))){
            $reason='PATH_UNSAFE';$path=Assert-BridgePlainPath $entry[0]
            $reason=$entry[2]+'_MISSING';if(-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop)){throw 'missing'}
            $reason=$entry[2]+'_HASH_CHANGED';if((Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ne $entry[1]){throw 'hash'}
        }
        $binding=[pscustomobject]@{manifest=$m;config=$b;proxy=$proxy;directory=$root;disabled=$disabled}
        return [pscustomobject]@{valid=$true;reasonCode='VALIDATED_NOT_CONNECTED';binding=$binding}
    }catch [UnauthorizedAccessException]{return [pscustomobject]@{valid=$false;reasonCode='ACCESS_DENIED';binding=$null}}
    catch{return [pscustomobject]@{valid=$false;reasonCode=$reason;binding=$null}}
}
function Get-ValidatedApiQuestionBridge {
    param([string]$Directory,[string]$ApiHome,[string]$Profile,[string]$DesktopExecutable,[string]$InstanceId,[switch]$IgnoreDisabled)
    $result=Get-ApiQuestionBridgeValidation @PSBoundParameters
    if($result.valid){return $result.binding}
    return $null
}
