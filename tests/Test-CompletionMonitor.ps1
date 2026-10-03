Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\src\CompletionMonitor.ps1"

$script:Passed = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:Passed++
    Write-Output "PASS: $Message"
}
function Append-Bytes([string]$Path, [byte[]]$Bytes) {
    $file = New-Object IO.FileStream($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $file.Write($Bytes, 0, $Bytes.Length) }
    finally { $file.Dispose() }
}
function Append-Line([string]$Path, $Record) {
    Append-Bytes $Path $script:CompletionEncoding.GetBytes(($Record | ConvertTo-Json -Compress -Depth 10) + "`n")
}
function Meta([string]$Id, [string]$Source = 'vscode', [string]$Originator = 'Codex Desktop') {
    return @{ type='session_meta'; payload=@{ id=$Id; source=$Source; originator=$Originator } }
}
function Complete([string]$Turn) {
    return @{ type='event_msg'; payload=@{ type='task_complete'; turn_id=$Turn; last_agent_message='PRIVATE_BAIT_NEVER_SAVE' } }
}
function New-Log([string]$SessionHome, [string]$DatePath, [string]$Name, $Metadata) {
    $day = Join-Path (Join-Path $SessionHome 'sessions') $DatePath
    [void][IO.Directory]::CreateDirectory($day)
    $path = Join-Path $day ($Name + '.jsonl')
    [IO.File]::WriteAllBytes($path, [byte[]]@())
    Append-Line $path $Metadata
    return $path
}
function Poll($Monitor) {
    $Monitor.NextScanUtc = [DateTime]::MinValue
    return ,@(Read-MonitorCompletions $Monitor)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('codex-completion-monitor-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$official = Join-Path $root 'official'
$api = Join-Path $root 'api'
$officialId = [guid]::NewGuid().ToString('N')
$apiId = [guid]::NewGuid().ToString('N')
$config = [pscustomobject]@{ stateDirectory=(Join-Path $root 'state'); instances=@(
    [pscustomobject]@{ id=$officialId; role='official'; home=$official },
    [pscustomobject]@{ id=$apiId; role='api'; home=$api }
) }
$statePath = Join-Path $root 'state\completion.json'
$monitor = $null
try {
    $historicThread = [guid]::NewGuid().ToString()
    $historic = New-Log $api '2021\07\04' 'historic' (Meta $historicThread)
    Append-Line $historic (Complete ([guid]::NewGuid().ToString()))
    $apiThread = [guid]::NewGuid().ToString()
    $apiLog = New-Log $api '2026\09\23' 'api' (Meta $apiThread)
    Append-Line $apiLog (Complete ([guid]::NewGuid().ToString()))
    $bad = New-Log $api '2026\09\22' 'bad-meta' (Meta ([guid]::NewGuid().ToString()) 'cli')
    $missingType = New-Log $api '2026\09\22' 'missing-type' @{ payload=@{
        id=[guid]::NewGuid().ToString(); source='vscode'; originator='Codex Desktop'
    } }
    $sub = New-Log $api '2026\09\23' 'subagent' @{ type='session_meta'; payload=@{
        id=[guid]::NewGuid().ToString(); source='vscode'; originator='Codex Desktop'; parent_thread_id=[guid]::NewGuid().ToString()
    } }
    $large = 'PRIVATE_BAIT_NEVER_SAVE' * 60000
    Append-Line $historic @{ type='response_item'; payload=@{ text=$large } }
    $monitor = New-CompletionMonitor $config $statePath
    $outsideRejected = $false
    try { [void](New-CompletionMonitor $config (Join-Path $root 'outside\completion.json')) } catch { $outsideRejected = $true }
    Assert $outsideRejected 'State path outside controller state directory is rejected'
    Assert ((Poll $monitor).Count -eq 0) 'First enable skips historical API completions'
    Assert ($monitor.Entries.Count -eq 5 -and @($monitor.Instances).Count -eq 1 -and $monitor.Instances[0].Id -eq $apiId) 'Baseline includes old API years and only the API instance'
    Assert (@($monitor.Warnings | Where-Object Code -eq 'InvalidMeta').Count -eq 3) 'Untrusted source, missing type, and subagent fail closed'
    Assert (-not ([IO.File]::ReadAllText($statePath)).Contains('PRIVATE_BAIT_NEVER_SAVE')) 'State excludes answer body and bait'

    $officialLog = New-Log $official '2026\09\23' 'official' (Meta ([guid]::NewGuid().ToString()))
    Append-Line $officialLog (Complete ([guid]::NewGuid().ToString()))
    Assert ((Poll $monitor).Count -eq 0 -and $monitor.Entries.Count -eq 5) 'New official session is never scanned or emitted'
    Append-Line $officialLog (Complete ([guid]::NewGuid().ToString()))
    Assert ((Poll $monitor).Count -eq 0 -and $monitor.Entries.Count -eq 5) 'Official session append remains silent'
    $historicTurn = [guid]::NewGuid().ToString()
    Append-Line $historic (Complete $historicTurn)
    $events = Poll $monitor
    Assert ($events.Count -eq 1 -and $events[0].InstanceId -eq $apiId -and
        $events[0].ThreadId -eq $historicThread -and $events[0].TurnId -eq $historicTurn) 'Old-year API session append retains owner'
    Assert (($events[0].PSObject.Properties.Name -join ',') -eq 'InstanceId,ThreadId,TurnId') 'Only completion identifiers leave reader'
    Assert ((Poll $monitor).Count -eq 0) 'Unchanged log does not re-emit'
    Append-Line $historic @{ payload=@{ type='task_complete'; turn_id=[guid]::NewGuid().ToString() } }
    Assert ((Poll $monitor).Count -eq 0) 'Event without a type is ignored under strict mode'
    Append-Line $historic (Complete $historicTurn)
    Assert ((Poll $monitor).Count -eq 0) 'Repeated same turn is deduplicated'
    $duplicateFile = New-Log $api '2026\09\23' 'duplicate-session' (Meta $historicThread)
    Append-Line $duplicateFile (Complete $historicTurn)
    Assert ((Poll $monitor).Count -eq 0) 'Same instance, thread, and turn across files is deduplicated'

    $apiTurn = [guid]::NewGuid().ToString()
    Append-Line $apiLog (Complete $apiTurn)
    $events = Poll $monitor
    Assert ($events.Count -eq 1 -and $events[0].InstanceId -eq $apiId -and $events[0].ThreadId -eq $apiThread) 'API environment remains independently attributed'
    $newThread = [guid]::NewGuid().ToString()
    $newFile = New-Log $api '2026\09\23' 'new-session' (Meta $newThread)
    $newTurn = [guid]::NewGuid().ToString()
    Append-Line $newFile (Complete $newTurn)
    Assert ((Poll $monitor)[0].TurnId -eq $newTurn) 'New file after enable reads from its beginning'
    $nextDay = New-Log $api '2026\09\24' 'next-day' (Meta ([guid]::NewGuid().ToString()))
    $nextTurn = [guid]::NewGuid().ToString()
    Append-Line $nextDay (Complete $nextTurn)
    $events = Poll $monitor
    Assert ($events.Count -eq 1 -and $events[0].InstanceId -eq $apiId -and $events[0].TurnId -eq $nextTurn) 'Next-day directory is discovered'
    $junction = Join-Path ([IO.Path]::GetDirectoryName($newFile)) 'linked-sessions'
    try {
        [void](New-Item -ItemType Junction -Path $junction -Target (Join-Path $api 'sessions') -ErrorAction Stop)
        $beforeLinks = $monitor.Entries.Count
        Assert ((Poll $monitor).Count -eq 0 -and $monitor.Entries.Count -eq $beforeLinks) 'Directory reparse point is not traversed'
        $blockedPath = Join-Path $junction '2026\09\24\next-day.jsonl'
        $blocked = $false
        try { [void](New-CompletionCursor $blockedPath $apiId) } catch { $blocked = $true }
        Assert $blocked 'Reader refuses a path through a reparse point'
        $stateJunction = Join-Path $config.stateDirectory 'linked'
        [void](New-Item -ItemType Junction -Path $stateJunction -Target $api -ErrorAction Stop)
        $stateLinkRejected = $false
        try { [void](New-CompletionMonitor $config (Join-Path $stateJunction 'completion.json')) } catch { $stateLinkRejected = $true }
        Assert $stateLinkRejected 'State path through a reparse point is rejected'
    } catch {
        if ($_.Exception.Message -like 'FAIL:*') { throw }
        Write-Output 'SKIP: junction unavailable in this Windows environment'
    }

    $partialTurn = [guid]::NewGuid().ToString()
    $line = $script:CompletionEncoding.GetBytes(((Complete $partialTurn) | ConvertTo-Json -Compress -Depth 10) + "`n")
    Append-Bytes $historic $line[0..($line.Length - 2)]
    Assert ((Poll $monitor).Count -eq 0) 'Incomplete JSONL line stays pending'
    Close-CompletionMonitor $monitor
    $monitor = New-CompletionMonitor $config $statePath
    Assert ((Poll $monitor).Count -eq 0) 'Restart does not replay delivered completions or partial line'
    Append-Bytes $historic ([byte[]]@($line[$line.Length - 1]))
    Assert ((Poll $monitor)[0].TurnId -eq $partialTurn) 'Partial line survives restart at full-line offset'

    Close-CompletionMonitor $monitor
    $offlineTurn = [guid]::NewGuid().ToString()
    Append-Line $apiLog (Complete $offlineTurn)
    $monitor = New-CompletionMonitor $config $statePath
    Assert ((Poll $monitor)[0].TurnId -eq $offlineTurn) 'Restart catches up an unread offline completion'
    Assert ((Poll $monitor).Count -eq 0) 'Caught-up event is durable before return'

    Close-CompletionMonitor $monitor
    $legacyState = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $apiSaved = @($legacyState.files | Where-Object instanceId -eq $apiId)
    $apiOffset = @($apiSaved | Where-Object path -eq $apiLog)[0].offset
    $officialCursor = New-CompletionCursor $officialLog $officialId
    try {
        [void](Read-NewCompletions $officialCursor)
        $officialEntry = [pscustomobject]@{path=$officialLog;instanceId=$officialId;fileIdentity=$officialCursor.FileIdentity;offset=$officialCursor.Offset;metaSeen=$officialCursor.MetaSeen;threadId=$officialCursor.ThreadId;seenTurns=@($officialCursor.SeenTurns);status=$officialCursor.Status;idleLength=$officialCursor.Stream.Length;lastWriteTicks=([IO.FileInfo]$officialLog).LastWriteTimeUtc.Ticks}
    } finally { Close-CompletionCursor $officialCursor }
    $legacyState.instances = @([pscustomobject]@{id=$officialId;home=$official},[pscustomobject]@{id=$apiId;home=$api})
    $legacyState.files = @($apiSaved) + @($officialEntry)
    [IO.File]::WriteAllText($statePath, ($legacyState | ConvertTo-Json -Depth 12), [Text.Encoding]::UTF8)
    $migrationTurn = [guid]::NewGuid().ToString()
    Append-Line $apiLog (Complete $offlineTurn)
    Append-Line $apiLog (Complete $migrationTurn)
    Append-Line $officialLog (Complete ([guid]::NewGuid().ToString()))
    $monitor = New-CompletionMonitor $config $statePath
    Assert (@($monitor.Entries.Values | Where-Object InstanceId -eq $officialId).Count -eq 0) 'Legacy dual-home state discards official cursors'
    Assert ($monitor.Entries[(Get-MonitorKey $apiId $apiLog)].Offset -eq $apiOffset) 'Legacy migration preserves API full-line offset'
    $events = Poll $monitor
    Assert ($events.Count -eq 1 -and $events[0].TurnId -eq $migrationTurn -and $events[0].InstanceId -eq $apiId) 'Legacy migration retains deduplication and catches unread API completion only'
    $migrated = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert ($migrated.schema -eq 1 -and @($migrated.instances).Count -eq 1 -and $migrated.instances[0].id -eq $apiId -and @($migrated.files | Where-Object instanceId -eq $officialId).Count -eq 0) 'Migrated schema1 state persists API ownership only'
    Close-CompletionMonitor $monitor
    $monitor = New-CompletionMonitor $config $statePath
    Assert ((Poll $monitor).Count -eq 0) 'Migrated single-API state restarts without replay'

    $invalidLegacyPath = Join-Path $config.stateDirectory 'wrong-legacy-binding.json'
    $legacyState.instances[0].home = Join-Path $root 'unrelated-official'
    [IO.File]::WriteAllText($invalidLegacyPath, ($legacyState | ConvertTo-Json -Depth 12), [Text.Encoding]::UTF8)
    $legacyRejected = $false
    try { [void](New-CompletionMonitor $config $invalidLegacyPath) } catch { $legacyRejected = $true }
    Assert $legacyRejected 'Legacy migration validates official binding before filtering it'

    $healthyTurn = [guid]::NewGuid().ToString()
    Append-Line $bad (Complete ([guid]::NewGuid().ToString()))
    Append-Line $apiLog (Complete $healthyTurn)
    Assert ((Poll $monitor)[0].TurnId -eq $healthyTurn) 'Bad file cannot block healthy file'
    Append-Bytes $historic $script:CompletionEncoding.GetBytes("{malformed-json`n")
    $safeTurn = [guid]::NewGuid().ToString()
    Append-Line $apiLog (Complete $safeTurn)
    Assert ((Poll $monitor)[0].TurnId -eq $safeTurn) 'Malformed event disables only its own file'
    Assert (@($monitor.Warnings | Where-Object Code -eq 'InvalidJson').Count -eq 1) 'Malformed event exposes a fixed warning code'
    $longFile = New-Log $api '2026\09\23' 'oversized-line' (Meta ([guid]::NewGuid().ToString()))
    [void](Poll $monitor)
    Append-Bytes $longFile (New-Object byte[] ($script:CompletionLineLimit + 1))
    Assert ((Poll $monitor).Count -eq 0) 'Oversized line never emits a completion'
    Assert (@($monitor.Warnings | Where-Object Code -eq 'LineTooLong').Count -eq 1) 'Oversized line disables its own file'
    $replacement = Join-Path ([IO.Path]::GetDirectoryName($newFile)) 'replaced-backup.old'
    [IO.File]::Move($newFile, $replacement)
    [IO.File]::WriteAllBytes($newFile, [byte[]]@())
    Append-Line $newFile (Meta $newThread)
    Append-Line $newFile (Complete ([guid]::NewGuid().ToString()))
    Assert ((Poll $monitor).Count -eq 0) 'Replacing a known path does not claim its new content'
    Assert (@($monitor.Warnings | Where-Object Code -eq 'Replaced').Count -eq 1) 'Replacement exposes a fixed warning code'
    [IO.File]::WriteAllBytes($apiLog, [byte[]]@())
    Assert ((Poll $monitor).Count -eq 0) 'Truncated file is not reread'
    Assert (@($monitor.Warnings | Where-Object Code -eq 'Truncated').Count -eq 1) 'Truncation exposes a fixed warning code'
    Assert (-not ([IO.File]::ReadAllText($statePath)).Contains('PRIVATE_BAIT_NEVER_SAVE')) 'Persistent state contains no reply text'
    Write-Output "PASSED: $script:Passed assertions. Temporary fixtures: $root"
} finally {
    if ($null -ne $monitor) { Close-CompletionMonitor $monitor }
}
