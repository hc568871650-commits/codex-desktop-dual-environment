[CmdletBinding()]
param([Parameter(Mandatory)][string]$BindingPath, [Parameter(Mandatory)][string]$BindingSha256)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ownedNode = $null; $desktopHandle = $null; $binding = $null; $mutex = $null; $held = $false
try {
    # Validate the pinned manifest before loading any helper from this installation.
    if ((Get-FileHash -LiteralPath $BindingPath -Algorithm SHA256).Hash -ne $BindingSha256) { throw 'title-binding-changed' }
    $raw = Get-Content -LiteralPath $BindingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $helper = Join-Path $PSScriptRoot 'TitleIntegrationLaunch.ps1'
    $pin = @($raw.bundleFiles | Where-Object path -eq 'native/TitleIntegrationLaunch.ps1')
    if ($pin.Count -ne 1 -or (Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash -ne $pin[0].sha256) { throw 'title-helper-changed' }
    . $helper
    $binding = Read-TitleBinding $BindingPath $BindingSha256
    if (Test-Path -LiteralPath (Join-Path $binding.installRoot 'DISABLED')) { exit 0 }
    $mutex = New-Object Threading.Mutex($false, ('Local\CodexTitleNative.' + $binding.instanceId))
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
    if (-not $held) { exit 0 }
    . (Join-Path $binding.controller.directory 'src\Instances.ps1')
    $context = Get-TitleControllerContext $binding
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    $process = $null; $child = $null; $endpoint = $null
    Write-TitleState (Join-Path $binding.stateDirectory 'launch-status.json') @{schema=1;state='waiting-for-desktop';updatedAt=[DateTime]::UtcNow.ToString('o')}
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath (Join-Path $binding.installRoot 'DISABLED')) { throw 'title-disabled' }
        $status = Get-InstanceStatus $context.Config $context.Instance
        if ($status.State -eq 'Running') {
            $process = $status.Process
            if (-not (Test-TitlePath $process.Path $binding.desktop.path)) { throw 'title-desktop-changed' }
            [void](Assert-CurrentIdentity $context.Instance $process)
            $child = Get-TitleRuntimeCliChild (Get-ProcessSnapshot) $process $binding $context.Config
            $debugFile = Join-Path $binding.profile 'DevToolsActivePort'
            if ($child -and (Test-Path -LiteralPath $debugFile)) {
                try { $endpoint = Read-TitleDebugEndpoint $binding.profile ([long]$process.Started) }
                catch { $endpoint=$null }
                if ($endpoint) { break }
            }
        } elseif ($status.State -ne 'Stopped') { throw 'title-instance-unknown' }
        Start-Sleep -Milliseconds 750
    }
    if (-not $process -or -not $child -or -not $endpoint) { throw 'title-startup-timeout' }
    [void](Assert-CurrentIdentity $context.Instance $process)
    $confirmedChild=Get-TitleRuntimeCliChild (Get-ProcessSnapshot) $process $binding $context.Config
    if($null -eq $confirmedChild -or -not (Test-ProcessIdentity $child $confirmedChild)){throw 'title-cli-identity-changed'}
    Assert-TitleListeners (Get-NetTCPConnection -State Listen -LocalPort $endpoint.Port -ErrorAction Stop) $endpoint.Port $process.Id
    $version = Invoke-RestMethod -Uri ('http://127.0.0.1:'+$endpoint.Port+'/json/version') -TimeoutSec 4
    Assert-TitleVersionEndpoint $version $endpoint.Port $endpoint.BrowserPath
    [void](Assert-CurrentIdentity $context.Instance $process)
    Assert-TitleListeners (Get-NetTCPConnection -State Listen -LocalPort $endpoint.Port -ErrorAction Stop) $endpoint.Port $process.Id
    $desktopHandle = [Diagnostics.Process]::GetProcessById($process.Id)
    $null = $desktopHandle.Handle
    if ([Math]::Abs($desktopHandle.StartTime.ToUniversalTime().Ticks-[long]$process.Started) -ge 10) { throw 'title-desktop-identity-changed' }
    $targetPath = Join-Path $binding.stateDirectory 'runtime-target.json'
    Write-TitleState $targetPath @{pid=$process.Id;startedTicks=[string]$process.Started;port=$endpoint.Port;browserPath=$endpoint.BrowserPath;desktopExe=$process.Path;profile=$binding.profile;home=$binding.home;cli=$child.Path}
    # The inherited key stays in environment; it never enters argv or status files.
    $env:CODEX_HOME = $binding.home
    $arguments = @((ConvertTo-TitleQuotedArgument (Join-Path $binding.installRoot 'native\loader.mjs')), '--binding', (ConvertTo-TitleQuotedArgument $BindingPath), '--target', (ConvertTo-TitleQuotedArgument $targetPath))
    $ownedNode = Start-Process -FilePath $binding.node.path -ArgumentList $arguments -WindowStyle Hidden -PassThru -WorkingDirectory $binding.installRoot
    $null = $ownedNode.Handle
    Write-TitleState (Join-Path $binding.stateDirectory 'launch-status.json') @{schema=1;state='loader-started';pid=$process.Id;nodePid=$ownedNode.Id;updatedAt=[DateTime]::UtcNow.ToString('o')}
    while (-not $desktopHandle.HasExited -and -not $ownedNode.HasExited) {
        if (Test-Path -LiteralPath (Join-Path $binding.installRoot 'DISABLED')) {
            Wait-TitleDisabledExit $ownedNode {
                [void](Assert-CurrentIdentity $context.Instance $process)
                Assert-TitleListeners (Get-NetTCPConnection -State Listen -LocalPort $endpoint.Port -ErrorAction Stop) $endpoint.Port $process.Id
            }
            throw 'title-disabled'
        }
        [void](Assert-CurrentIdentity $context.Instance $process)
        Assert-TitleListeners (Get-NetTCPConnection -State Listen -LocalPort $endpoint.Port -ErrorAction Stop) $endpoint.Port $process.Id
        Start-Sleep -Seconds 2
    }
    $result = if ($desktopHandle.HasExited) {'desktop-exited'} else {'loader-exited'}
    Write-TitleState (Join-Path $binding.stateDirectory 'launch-status.json') @{schema=1;state=$result;updatedAt=[DateTime]::UtcNow.ToString('o')}
} catch {
    if ($binding) {
        # Exception strings can contain command arguments; persist a fixed category only.
        $reason = if ($_.Exception.Message -match '^title-[a-z-]+$') { $_.Exception.Message } else { 'title-validation-or-start-failed' }
        Write-TitleState (Join-Path $binding.stateDirectory 'launch-status.json') @{schema=1;state='disabled-for-launch';reason=$reason;updatedAt=[DateTime]::UtcNow.ToString('o')}
    }
} finally {
    if ($ownedNode) { try { if (-not $ownedNode.HasExited) { $ownedNode.Kill(); $ownedNode.WaitForExit(3000) | Out-Null } } catch {}; $ownedNode.Dispose() }
    if ($desktopHandle) { $desktopHandle.Dispose() }
    if ($mutex) { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
