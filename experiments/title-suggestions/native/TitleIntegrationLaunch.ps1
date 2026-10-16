Set-StrictMode -Version Latest

function Get-TitleSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}
function Test-TitlePath([string]$Left, [string]$Right) {
    if (-not $Left -or -not $Right) { return $false }
    return [IO.Path]::GetFullPath($Left).TrimEnd('\').Equals([IO.Path]::GetFullPath($Right).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}
function Assert-TitleRegularPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'title-reparse-path' }
        $parent = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
        $item = $parent
    }
}
function Write-TitleState([string]$Path, $Value) {
    $folder = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($folder)
    Assert-TitleRegularPath $folder
    $temp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { Assert-TitleRegularPath $Path; [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
function Read-TitleBinding([string]$BindingPath, [string]$BindingSha256) {
    Assert-TitleRegularPath $BindingPath
    if ($BindingSha256 -notmatch '^[0-9a-fA-F]{64}$' -or (Get-TitleSha256 $BindingPath) -ne $BindingSha256) { throw 'title-binding-changed' }
    $binding = Get-Content -LiteralPath $BindingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($binding.schema -ne 1 -or $binding.instanceId -notmatch '^[a-f0-9]{32}$') { throw 'title-binding-invalid' }
    if (-not $binding.PSObject.Properties['compatibility']) { throw 'title-compatibility-receipt-invalid' }
    Assert-TitleCompatibilityReceipt $binding.compatibility $binding.cli.sha256
    if (-not (Test-TitlePath (Split-Path -Parent $BindingPath) $binding.installRoot)) { throw 'title-install-root-mismatch' }
    if (-not (Test-TitlePath $binding.stateDirectory (Join-Path $binding.installRoot 'state'))) { throw 'title-state-root-mismatch' }
    foreach ($binary in @($binding.desktop, $binding.cli, $binding.node, $binding.python)) {
        Assert-TitleRegularPath $binary.path
        if ((Get-TitleSha256 $binary.path) -ne $binary.sha256) { throw 'title-runtime-changed' }
    }
    foreach ($entry in @($binding.bundleFiles)) {
        if ([IO.Path]::IsPathRooted($entry.path) -or $entry.path -match '(^|[\\/])\.\.([\\/]|$)') { throw 'title-bundle-path-invalid' }
        $file = Join-Path $binding.installRoot $entry.path
        Assert-TitleRegularPath $file
        if ((Get-TitleSha256 $file) -ne $entry.sha256) { throw 'title-bundle-changed' }
    }
    foreach ($entry in @($binding.controller.dependencies)) {
        Assert-TitleRegularPath $entry.path
        if ((Get-TitleSha256 $entry.path) -ne $entry.sha256) { throw 'title-controller-changed' }
    }
    return $binding
}
function Assert-TitleCompatibilityReceipt($Receipt, [string]$CliSha256) {
    if ($null -eq $Receipt -or $Receipt.passed -isnot [bool] -or -not $Receipt.passed -or
        $Receipt.environmentHeaderVerified -isnot [bool] -or -not $Receipt.environmentHeaderVerified -or
        ($Receipt.toolCount -isnot [int] -and $Receipt.toolCount -isnot [long]) -or $Receipt.toolCount -ne 0 -or $Receipt.cliSha256 -ne $CliSha256) {
        throw 'title-compatibility-receipt-invalid'
    }
}
function Wait-TitleDisabledExit($OwnedNode,[scriptblock]$ValidateIdentity,[int]$GraceMilliseconds=10000) {
    # The loader polls DISABLED itself, detaches its renderer, and cancels workers.
    # Identity changes bypass this grace period and reach the owning wrapper's immediate kill.
    $deadline=[DateTime]::UtcNow.AddMilliseconds($GraceMilliseconds)
    while (-not $OwnedNode.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        & $ValidateIdentity
        [void]$OwnedNode.WaitForExit([Math]::Min(250,[Math]::Max(1,[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds)))
    }
}
function Get-TitleControllerContext($Binding) {
    . (Join-Path $Binding.controller.directory 'src\Instances.ps1')
    $config = Read-ControllerConfig $Binding.controller.configPath
    $instance = Get-ApiFeatureInstance $config $Binding.instanceId
    if ($null -eq $instance -or -not (Test-SamePath $instance.home $Binding.home) -or -not (Test-SamePath $instance.profile $Binding.profile)) { throw 'title-api-binding-mismatch' }
    return [pscustomobject]@{ Config=$config; Instance=$instance }
}
function Get-TitleIntegrationLaunch {
    param([Parameter(Mandatory)][string]$BindingPath, [Parameter(Mandatory)][string]$BindingSha256,
          [Parameter(Mandatory)][string]$ApiHome, [Parameter(Mandatory)][string]$Profile,
          [Parameter(Mandatory)][string]$DesktopExecutable)
    $binding = Read-TitleBinding $BindingPath $BindingSha256
    if (Test-Path -LiteralPath (Join-Path $binding.installRoot 'DISABLED')) { return $null }
    if (-not (Test-TitlePath $ApiHome $binding.home) -or -not (Test-TitlePath $Profile $binding.profile) -or -not (Test-TitlePath $DesktopExecutable $binding.desktop.path)) { throw 'title-launch-binding-mismatch' }
    # Existing processes cannot acquire new Chromium switches. Leave their native startup untouched.
    . (Join-Path $binding.controller.directory 'src\Instances.ps1')
    $context = Get-TitleControllerContext $binding
    $status = Get-InstanceStatus $context.Config $context.Instance
    if ($status.State -eq 'Running') { return $null }
    if ($status.State -ne 'Stopped') { throw 'title-instance-unknown' }
    return [pscustomobject]@{
        debugArguments=@('--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1')
        daemon=(Join-Path $binding.installRoot 'native\Start-TitleIntegration.ps1')
        bindingPath=$BindingPath; bindingSha256=$BindingSha256
    }
}
function Read-TitleDebugEndpoint([string]$Profile, [long]$StartedTicks) {
    $path = Join-Path $Profile 'DevToolsActivePort'
    Assert-TitleRegularPath $path
    $info = Get-Item -LiteralPath $path
    if ($info.Length -gt 512 -or $info.LastWriteTimeUtc.Ticks -lt $StartedTicks) { throw 'title-debug-file-stale' }
    $lines = [IO.File]::ReadAllLines($path, [Text.Encoding]::ASCII)
    if ($lines.Count -ne 2 -or $lines[0] -notmatch '^[0-9]{1,5}$' -or $lines[1] -notmatch '^/devtools/browser/[a-fA-F0-9-]{32,36}$') { throw 'title-debug-file-invalid' }
    $port = [int]$lines[0]
    if ($port -lt 1 -or $port -gt 65535) { throw 'title-debug-port-invalid' }
    return [pscustomobject]@{ Port=$port; BrowserPath=$lines[1] }
}
function Assert-TitleListeners($Listeners, [int]$Port, [int]$ProcessId) {
    $items = @($Listeners | Where-Object { $_.LocalPort -eq $Port -and [string]$_.State -eq 'Listen' })
    if ($items.Count -eq 0) { throw 'title-debug-not-listening' }
    foreach ($item in $items) {
        if ([int]$item.OwningProcess -ne $ProcessId -or $item.LocalAddress -notin @('127.0.0.1','::1')) { throw 'title-debug-owner-or-address-mismatch' }
    }
}
function Assert-TitleVersionEndpoint($Version, [int]$Port, [string]$BrowserPath) {
    $url = [Uri]$Version.webSocketDebuggerUrl
    if ($url.Scheme -ne 'ws' -or $url.Host -notin @('127.0.0.1','[::1]','::1') -or $url.Port -ne $Port -or $url.AbsolutePath -cne $BrowserPath -or $url.Query -or $url.Fragment -or $url.UserInfo) { throw 'title-browser-endpoint-mismatch' }
}
function Get-TitleCliChild($Snapshot, [int]$ParentProcessId, $CliBinding) {
    $children = @($Snapshot | Where-Object { $_.ParentId -eq $ParentProcessId -and [IO.Path]::GetFileName($_.Path) -ieq 'codex.exe' })
    if ($children.Count -gt 1) { throw 'title-cli-child-ambiguous' }
    if ($children.Count -eq 0) { return $null }
    if (-not (Test-TitlePath $children[0].Path $CliBinding.path) -or (Get-TitleSha256 $children[0].Path) -ne $CliBinding.sha256) { throw 'title-cli-child-changed' }
    return $children[0]
}
function Get-TitleValidatedQuestionBridge($TitleBinding, $ControllerConfig) {
    # Never load an arbitrary registration-supplied helper. The controller validator
    # must be pinned by this title installation, and revalidated before dot-sourcing.
    $validator=Join-Path $TitleBinding.controller.directory 'src\QuestionBridgeLaunch.ps1'
    $pins=@($TitleBinding.controller.dependencies | Where-Object { Test-TitlePath $_.path $validator })
    if($pins.Count -ne 1){throw 'title-bridge-validator-unpinned'}
    Assert-TitleRegularPath $validator
    if((Get-TitleSha256 $validator) -ne $pins[0].sha256){throw 'title-bridge-validator-changed'}
    $registrationPath=Join-Path $ControllerConfig.stateDirectory 'question-bridge.local.json'
    $stream=$null
    try {
        Assert-TitleRegularPath $registrationPath
        $stream=[IO.File]::Open($registrationPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        if($stream.Length -gt 65536){throw 'size'}
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        try {
            $chars=New-Object char[] 65537;$count=$reader.ReadBlock($chars,0,$chars.Length)
            if($count -gt 65536){throw 'size'}
            $raw=New-Object string($chars,0,$count)
        }finally{$reader.Dispose();$stream=$null}
        $registration=ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        if($registration -isnot [pscustomobject] -or $registration.schema -ne 1 -or $registration.instanceId -cne $TitleBinding.instanceId){throw 'identity'}
        $directory=[string]$registration.directory
        if(-not [IO.Path]::IsPathRooted($directory) -or $directory.StartsWith('\\')){throw 'path'}
    }catch{throw 'title-bridge-registration-invalid'}
    finally{if($stream){$stream.Dispose()}}
    . $validator
    $validation=Get-ApiQuestionBridgeValidation -Directory $directory -ApiHome $TitleBinding.home -Profile $TitleBinding.profile -DesktopExecutable $TitleBinding.desktop.path -InstanceId $TitleBinding.instanceId
    if(-not $validation.valid){throw 'title-question-bridge-invalid'}
    $bridge=$validation.binding
    if(-not (Test-TitlePath $bridge.manifest.realCli $TitleBinding.cli.path) -or $bridge.manifest.realCliHash -ne $TitleBinding.cli.sha256){throw 'title-bridge-cli-binding-mismatch'}
    return $bridge
}
function Get-TitleRuntimeCliChild($Snapshot, $DesktopProcess, $TitleBinding, $ControllerConfig) {
    $children=@($Snapshot | Where-Object {$_.ParentId -eq $DesktopProcess.Id})
    $direct=@($children | Where-Object {[IO.Path]::GetFileName($_.Path) -ieq 'codex.exe'})
    $proxies=@($children | Where-Object {[IO.Path]::GetFileName($_.Path) -ieq 'BridgeProxy.exe'})
    if($direct.Count -gt 1 -or $proxies.Count -gt 1 -or ($direct.Count -and $proxies.Count)){throw 'title-cli-child-ambiguous'}
    if($direct.Count){
        $child=Get-TitleCliChild $Snapshot $DesktopProcess.Id $TitleBinding.cli
        if([string]$child.Started -notmatch '^[0-9]{15,20}$' -or [long]$child.Started -lt [long]$DesktopProcess.Started){throw 'title-cli-parent-identity-changed'}
        return $child
    }
    if(-not $proxies.Count){return $null}
    $bridge=Get-TitleValidatedQuestionBridge $TitleBinding $ControllerConfig
    $proxy=$proxies[0]
    if(-not (Test-TitlePath $proxy.Path $bridge.proxy) -or (Get-TitleSha256 $proxy.Path) -ne $bridge.manifest.proxyHash){throw 'title-bridge-process-mismatch'}
    if([string]$proxy.Started -notmatch '^[0-9]{15,20}$' -or [long]$proxy.Started -lt [long]$DesktopProcess.Started){throw 'title-bridge-parent-identity-changed'}
    # No arbitrary descendant scan: exactly one direct child of the validated proxy.
    $child=Get-TitleCliChild $Snapshot $proxy.Id $TitleBinding.cli
    if($null -eq $child){return $null}
    if([string]$child.Started -notmatch '^[0-9]{15,20}$' -or [long]$child.Started -lt [long]$proxy.Started){throw 'title-cli-parent-identity-changed'}
    return $child
}
function ConvertTo-TitleQuotedArgument([string]$Value) {
    if ($Value -match '["\r\n]') { throw 'title-argument-invalid' }
    return '"' + $Value.TrimEnd('\') + '"'
}
