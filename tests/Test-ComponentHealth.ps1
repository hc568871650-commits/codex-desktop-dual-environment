$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
. "$PSScriptRoot\..\src\Diagnostics.ps1"
$script:passed=0
function Check($Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)};$script:passed++;Write-Output ('PASS: '+$Message)}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('component-health-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
function Json([string]$Path,$Value){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 5))}
$api=[pscustomobject]@{id='abcdef0123456789abcdef0123456789';role='api';home=(Join-Path $fixture 'api-home');profile=(Join-Path $fixture 'api-profile')}
$official=[pscustomobject]@{role='official';home=(Join-Path $fixture 'official-home');profile=''}
$config=[pscustomobject]@{instances=@($api,$official);stateDirectory=(Join-Path $fixture 'state')}
$guard=Join-Path $api.home 'plugin-state\first-token-guard';$snapshot=Join-Path $guard 'desktop-status.json';$settings=Join-Path $guard 'desktop-settings.json'
$notifications=Join-Path $config.stateDirectory 'notifications';$worker=Join-Path $notifications 'worker-status.local.json'
function Component([string]$Name){@(Get-ControllerComponentHealth $config)|Where-Object {$_.component -eq $Name}}
function Stamp {([DateTimeOffset]::UtcNow-([DateTimeOffset]'1970-01-01T00:00:00Z')).TotalSeconds-1}
try {
    $before=@(Get-ChildItem -LiteralPath $fixture -Recurse -Force).Count
    $missing=Get-ControllerComponentHealth $config
    Check (@(Get-ChildItem -LiteralPath $fixture -Recurse -Force).Count -eq $before) 'missing components are never initialized'
    Check ((Component 'bridge').reasonCode -eq 'NOT_CONFIGURED') 'missing bridge registration is explicit'
    Check ($missing.Count -eq 6 -and @($missing.component|Select-Object -Unique).Count -eq 6) 'original five components remain alongside adaptive bridge'
    Check ((Component 'adaptiveBridge').reasonCode -eq 'NOT_CONFIGURED') 'missing adaptive registration is explicit and read only'
    Json $settings @{enabled=$true;cli_executable=(Join-Path $fixture 'old-cli.exe');secret='SECRET-BAIT'}
    Json $snapshot @{last_check=(Stamp);pid=12345;state='standby';error=$null}
    Json (Join-Path $notifications 'settings.local.json') @{schema=1;enabled=$true}
    Json $worker @{schema=1;runId=('a'*32);state='running';utc=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')}
    Check ((Component 'guard').reasonCode -eq 'HEARTBEAT_FRESH') 'guard reports recent heartbeat without claiming process identity'
    Check ((Component 'guardCli').reasonCode -eq 'CLI_MISSING') 'old guard CLI missing is actionable'
    Check ((Component 'guardTray').reasonCode -eq 'TRAY_UNOBSERVED') 'tray identity is never guessed from backend snapshot'
    Check ((Component 'notifications').reasonCode -eq 'HEARTBEAT_FRESH') 'notification heartbeat is read independently'
    $baseline=Get-FileHash $settings
    foreach($bad in @('', '{', '[]', '{}', ('a'*1048577))){
        [IO.File]::WriteAllText($snapshot,$bad)
        $item=Component 'guard'
        Check ($item.observedState -eq 'unknown') 'malformed empty missing-fields oversized snapshots remain unknown'
    }
    [IO.File]::WriteAllBytes($snapshot,(New-Object byte[] 100))
    Check ((Component 'guard').reasonCode -eq 'SNAPSHOT_INVALID') 'zero-filled snapshot is detected'
    Check ((Get-FileHash $settings).Hash -eq $baseline.Hash) 'diagnostics do not repair settings'
    Json $snapshot @{last_check=((Stamp)+600);pid=12345;state='standby'}
    Check ((Component 'guard').reasonCode -eq 'TIME_INVALID') 'future guard heartbeat is not fresh'
    Json $snapshot @{last_check=((Stamp)-100);pid=12345;state='monitoring'}
    Check ((Component 'guard').reasonCode -eq 'HEARTBEAT_STALE') 'stale guard heartbeat is reported'
    Json $snapshot @{last_check=(Stamp);pid=$null;state='stopped'}
    $stopped=Component 'guard'
    Check ($stopped.reasonCode -eq 'WORKER_STOPPED' -and $stopped.observedState -eq 'stopped') 'legitimate stopped snapshot is not corrupt'
    Json $settings @{enabled=$false;cli_executable=(Join-Path $fixture 'old-cli.exe')}
    $stopped=Component 'guard'
    Check ($stopped.reasonCode -eq 'WORKER_STOPPED' -and $stopped.configured -eq $false -and $stopped.observedState -eq 'disabled') 'disabled stopped backend preserves both states'
    $disabledLabel=-join (@(0x914d,0x7f6e,0x5df2,0x505c,0x7528)|ForEach-Object {[char]$_})
    Check ((Get-ComponentHealthText $stopped).Contains($disabledLabel)) 'rendered stopped state retains disabled configuration'
    Json $settings @{enabled=$true;cli_executable=(Join-Path $fixture 'old-cli.exe')}
    foreach($state in @('stopped','unknown','')){
        Json $snapshot @{last_check=(Stamp);pid=12345;state=$state}
        Check ((Component 'guard').reasonCode -eq 'SNAPSHOT_INVALID') 'contradictory stopped or unknown state cannot be fresh'
    }
    Json $snapshot @{last_check=(Stamp);state='stopped'}
    Check ((Component 'guard').reasonCode -eq 'SNAPSHOT_INVALID') 'missing pid is not treated as explicit stopped pid null'
    Json $snapshot @{last_check=(Stamp);pid=12345;state='error';error=$null}
    Check ((Component 'guard').reasonCode -eq 'BACKEND_ERROR') 'error state is respected even without error text'
    Json $worker @{schema=1;runId=('a'*32);state='running';utc=[DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o')}
    Check ((Component 'notifications').reasonCode -eq 'TIME_INVALID') 'future worker heartbeat is not fresh'
    Json $worker @{schema=1;runId=('a'*32);state='failed';utc=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')}
    Check ((Component 'notifications').reasonCode -eq 'WORKER_FAILED') 'worker failure is distinct from stale heartbeat'
    $items=Get-ControllerComponentHealth $config;$serialized=$items|ConvertTo-Json -Depth 5
    Check (-not $serialized.Contains($fixture) -and -not $serialized.Contains('SECRET-BAIT')) 'component report excludes paths and raw settings'
    Check ($null -eq (Get-ComponentHealthText ([pscustomobject]@{component='guard';reasonCode='SECRET-BAIT'}))) 'text renders only known reason codes'
    $adaptiveRoot=Join-Path $fixture 'adaptive';$adaptiveRegistration=Join-Path $config.stateDirectory 'adaptive-bridge.local.json';$adaptiveStatus=Join-Path $adaptiveRoot 'state\status.json'
    $registered=@{schema=1;instanceId=$api.id;root=$adaptiveRoot;enabled=$true}
    $adaptive=@{schema=1;instanceId=$api.id;apiHome=$api.home;profile=$api.profile;state='normal';reason='SECRET-BAIT';updatedUtc=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o');candidateDirectory='SECRET-BAIT'}
    Json $adaptiveRegistration $registered;Json $adaptiveStatus $adaptive
    $baselineAdaptive=Get-FileHash $adaptiveStatus
    Check ((Component 'adaptiveBridge').reasonCode -eq 'ADAPTIVE_BOUND_ONLY' -and (Component 'adaptiveBridge').observedState -eq 'validated') 'normal means bound only and never connection confirmed'
    foreach($pair in @(@('waiting_restart','ADAPTIVE_WAITING_START'),@('validating','ADAPTIVE_VERIFYING'),@('needs_adaptation','ADAPTIVE_NEEDS_ADAPTATION'),@('disabled','ADAPTIVE_DISABLED'))){
        $adaptive.state=$pair[0];Json $adaptiveStatus $adaptive
        Check ((Component 'adaptiveBridge').reasonCode -eq $pair[1]) ('adaptive state mapped without raw reason: '+$pair[0])
    }
    $adaptive.state='attached';Json $adaptiveStatus $adaptive
    Check ((Component 'adaptiveBridge').reasonCode -eq 'SNAPSHOT_INVALID') 'unsupported connection claim is rejected'
    $adaptive.state='normal';$adaptive.instanceId='0123456789abcdef0123456789abcdef';Json $adaptiveStatus $adaptive
    Check ((Component 'adaptiveBridge').reasonCode -eq 'IDENTITY_MISMATCH') 'cross instance adaptive status is rejected'
    $adaptive.instanceId=$api.id;$adaptive.apiHome=$official.home;Json $adaptiveStatus $adaptive
    Check ((Component 'adaptiveBridge').reasonCode -eq 'IDENTITY_MISMATCH') 'official home cannot supply API adaptive evidence'
    $adaptive.apiHome=$api.home;$adaptive.profile=Join-Path $fixture 'other-profile';Json $adaptiveStatus $adaptive
    Check ((Component 'adaptiveBridge').reasonCode -eq 'IDENTITY_MISMATCH') 'foreign profile cannot supply adaptive evidence'
    $adaptive.profile=$api.profile;$adaptive.updatedUtc=[DateTimeOffset]::UtcNow.AddDays(-8).ToString('o');Json $adaptiveStatus $adaptive
    Check ((Component 'adaptiveBridge').reasonCode -eq 'ADAPTIVE_STATUS_STALE') 'persisted adaptive result older than seven days is stale'
    $adaptive.state='validating';$adaptive.updatedUtc=[DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o');Json $adaptiveStatus $adaptive
    Check ((Component 'adaptiveBridge').reasonCode -eq 'ADAPTIVE_STATUS_STALE') 'stuck validation is not advertised as live work'
    $adaptive.updatedUtc=[DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o');Json $adaptiveStatus $adaptive
    Check ((Component 'adaptiveBridge').reasonCode -eq 'TIME_INVALID') 'future adaptive time is rejected'
    foreach($bad in @('{','[]','{}',('a'*65537))){[IO.File]::WriteAllText($adaptiveStatus,$bad);Check ((Component 'adaptiveBridge').observedState -eq 'unknown') 'malformed or oversized adaptive status remains unknown'}
    $registered.enabled=$false;Json $adaptiveRegistration $registered
    Check ((Component 'adaptiveBridge').reasonCode -eq 'ADAPTIVE_DISABLED') 'explicit registration disable overrides corrupt stale status'
    $registered.enabled=$true;Json $adaptiveRegistration $registered;[IO.File]::WriteAllText((Join-Path $adaptiveRoot 'DISABLED'),'stop')
    Check ((Component 'adaptiveBridge').configured -eq $false) 'root disabled marker overrides enabled registration'
    Remove-Item -LiteralPath (Join-Path $adaptiveRoot 'DISABLED')
    $registered.root=$api.home;Json $adaptiveRegistration $registered
    Check ((Component 'adaptiveBridge').reasonCode -eq 'PATH_UNSAFE') 'adaptive root overlapping instance is rejected before reading status'
    $registered.root='\\server\share\adaptive';Json $adaptiveRegistration $registered
    Check ((Component 'adaptiveBridge').reasonCode -eq 'PATH_UNSAFE') 'network adaptive root is rejected'
    $registered.root=$adaptiveRoot;$registered.instanceId='0123456789abcdef0123456789abcdef';Json $adaptiveRegistration $registered
    Check ((Component 'adaptiveBridge').reasonCode -eq 'IDENTITY_MISMATCH') 'cross instance adaptive registration rejected'
    $registered.instanceId=$api.id;Json $adaptiveRegistration $registered
    $adaptive.state='normal';$adaptive.updatedUtc=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o');Json $adaptiveStatus $adaptive
    $beforeAdaptiveHash=(Get-FileHash $adaptiveStatus).Hash;$beforeRegistrationHash=(Get-FileHash $adaptiveRegistration).Hash
    $report=Get-ControllerComponentHealth $config;$serialized=$report|ConvertTo-Json -Depth 5
    Check (-not $serialized.Contains($fixture) -and -not $serialized.Contains('SECRET-BAIT')) 'adaptive report excludes candidate paths and raw failure detail'
    Check ((Get-FileHash $adaptiveStatus).Hash -eq $beforeAdaptiveHash -and (Get-FileHash $adaptiveRegistration).Hash -eq $beforeRegistrationHash) 'adaptive diagnostics never repair or rewrite status and registration'
    Check (@($report|Where-Object {$_.component -in @('notifications','bridge','guard','guardCli','guardTray')}).Count -eq 5) 'all five preexisting component rows preserved'
    $api.profile=$official.home
    Check (@(Get-ControllerComponentHealth $config|Where-Object {$_.reasonCode -ne 'PATH_CONFLICT'}).Count -eq 0) 'directory conflict stops all component reads'
    Write-Output ('Component health: '+$script:passed+' checks passed; no service or API invoked.')
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture)
    if($resolved.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('component-health-')){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
