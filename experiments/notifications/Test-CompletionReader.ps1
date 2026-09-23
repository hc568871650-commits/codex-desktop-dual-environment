Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\CompletionReader.ps1"

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
function Meta($Id, $Source = 'vscode', $Originator = 'Codex Desktop') {
    return @{ type = 'session_meta'; payload = @{ id = $Id; source = $Source; originator = $Originator } }
}
function Event($Type, $TurnId) {
    return @{ type = 'event_msg'; payload = @{ type = $Type; turn_id = $TurnId; last_agent_message = 'SECRET: cannot leave reader' } }
}

$root = Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\..\test-results")) ('completion-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$instance = [guid]::NewGuid().ToString('N')
$thread = [guid]::NewGuid().ToString()
$turn = [guid]::NewGuid().ToString()
$path = Join-Path $root 'main.jsonl'
$cursors = New-Object 'System.Collections.Generic.List[object]'
try {
    [IO.File]::WriteAllBytes($path, [byte[]]@())
    $cursor = New-CompletionCursor $path $instance
    $cursors.Add($cursor)
    Assert ($cursor.Status -eq 'AwaitingMeta') 'Empty log awaits metadata'
    Append-Line $path (Meta $thread)
    Assert ((Read-NewCompletions $cursor).Status -eq 'Ready') 'Metadata arriving after empty file is accepted'
    Append-Line $path (Event 'task_started' $turn)
    Append-Line $path (Event 'token_count' $turn)
    Append-Line $path (Event 'item_completed' $turn)
    Assert (@((Read-NewCompletions $cursor).Completions).Count -eq 0) 'Non-completion events ignored'
    $line = (Event 'task_complete' $turn | ConvertTo-Json -Compress -Depth 10) + "`n"
    $bytes = $script:CompletionEncoding.GetBytes($line)
    Append-Bytes $path $bytes[0..($bytes.Length - 2)]
    Assert (@((Read-NewCompletions $cursor).Completions).Count -eq 0) 'Partial line is held'
    Append-Bytes $path ([byte[]]@($bytes[$bytes.Length - 1]))
    $result = Read-NewCompletions $cursor
    Assert ($result.Completions.Count -eq 1 -and $result.Completions[0].TurnId -eq $turn) 'Complete line emits one turn'
    Assert (($result.Completions[0].PSObject.Properties.Name -join ',') -eq 'InstanceId,ThreadId,TurnId' -and
        ($result | ConvertTo-Json -Depth 5) -notmatch 'SECRET|main.jsonl') 'Output excludes payload and path'
    Append-Line $path (Event 'task_complete' $turn)
    Assert (@((Read-NewCompletions $cursor).Completions).Count -eq 0) 'Repeated turn is deduplicated'

    $utfTurn = [guid]::NewGuid().ToString()
    $utfLine = (Event 'task_complete' $utfTurn | ConvertTo-Json -Compress -Depth 10).Replace('SECRET', ([string][char]0x4e2d + 'SECRET')) + "`n"
    $utf = $script:CompletionEncoding.GetBytes($utfLine)
    $split = [Array]::IndexOf($utf, [byte]0xE4) + 1
    Assert ($split -gt 0) 'Fixture contains a multibyte UTF-8 sequence'
    Append-Bytes $path $utf[0..($split - 1)]
    Assert (@((Read-NewCompletions $cursor).Completions).Count -eq 0) 'UTF-8 split is buffered as bytes'
    Append-Bytes $path $utf[$split..($utf.Length - 1)]
    Assert (@((Read-NewCompletions $cursor).Completions).Count -eq 1) 'UTF-8 split completes safely'

    Append-Line $path (Event 'task_complete' 'not-a-uuid')
    Append-Bytes $path $script:CompletionEncoding.GetBytes("{broken json`n")
    $bad = Read-NewCompletions $cursor
    Assert ($bad.Completions.Count -eq 0 -and $bad.SkippedLines -eq 2) "Invalid ID and malformed event skipped (status=$($bad.Status), count=$($bad.SkippedLines))"

    $historic = Join-Path $root 'historic.jsonl'
    [IO.File]::WriteAllBytes($historic, [byte[]]@())
    Append-Line $historic (Meta $thread)
    Append-Line $historic (Event 'task_complete' ([guid]::NewGuid().ToString()))
    $normal = New-CompletionCursor $historic $instance
    $cursors.Add($normal)
    Assert (@((Read-NewCompletions $normal).Completions).Count -eq 0) 'Default cursor skips history'
    $newTurn = [guid]::NewGuid().ToString()
    Append-Line $historic (Event 'task_complete' $newTurn)
    Assert ((Read-NewCompletions $normal).Completions[0].TurnId -eq $newTurn) 'Default cursor reads new completion'
    $fromStart = New-CompletionCursor $historic $instance -FromStart
    $cursors.Add($fromStart)
    Assert (@((Read-NewCompletions $fromStart).Completions).Count -eq 2) 'FromStart reads isolated fixture history'

    foreach ($variant in @(
        @{ Name = 'subagent'; Meta = @{ type = 'session_meta'; payload = @{ id = $thread; source = @{ subagent = @{} }; originator = 'Codex Desktop'; thread_source = 'subagent' } } },
        @{ Name = 'missing-meta-id'; Meta = (Meta $null) },
        @{ Name = 'unknown-source'; Meta = (Meta $thread 'cli') },
        @{ Name = 'unknown-originator'; Meta = (Meta $thread 'vscode' 'Codex CLI') },
        @{ Name = 'invalid-thread-id'; Meta = (Meta 'not-a-uuid') }
    )) {
        $fixture = Join-Path $root ($variant.Name + '.jsonl')
        [IO.File]::WriteAllBytes($fixture, [byte[]]@())
        Append-Line $fixture $variant.Meta
        Append-Line $fixture (Event 'task_complete' ([guid]::NewGuid().ToString()))
        $blocked = New-CompletionCursor $fixture $instance -FromStart
        $cursors.Add($blocked)
        $read = Read-NewCompletions $blocked
        Assert ($read.Status -eq 'InvalidMeta' -and $read.Completions.Count -eq 0) ($variant.Name + ' fails closed')
    }
    [IO.File]::WriteAllBytes($historic, [byte[]]@())
    Assert ((Read-NewCompletions $normal).Status -eq 'Truncated') 'Truncation fails closed'

    $replacement = Join-Path $root 'replacement.jsonl'
    [IO.File]::WriteAllBytes($replacement, [byte[]]@())
    Append-Line $replacement (Meta $thread)
    $old = New-CompletionCursor $replacement $instance
    $cursors.Add($old)
    $moved = Join-Path $root 'moved.jsonl'
    [IO.File]::Move($replacement, $moved)
    [IO.File]::WriteAllBytes($replacement, [byte[]]@())
    Append-Line $replacement (Meta $thread)
    Assert ((Read-NewCompletions $old).Status -eq 'Replaced') 'File replacement fails closed'

    $long = Join-Path $root 'large-meta.jsonl'
    [IO.File]::WriteAllBytes($long, [byte[]]@())
    Append-Bytes $long (New-Object byte[] ($script:CompletionLineLimit + 1))
    $limited = New-CompletionCursor $long $instance
    $cursors.Add($limited)
    Assert ($limited.Status -eq 'InvalidMeta') 'Metadata read is bounded'
    Write-Output "PASSED: $script:Passed assertions. Fixtures: $root"
} finally {
    foreach ($item in $cursors) { Close-CompletionCursor $item }
}
