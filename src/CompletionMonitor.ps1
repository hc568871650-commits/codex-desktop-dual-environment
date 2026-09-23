Set-StrictMode -Version Latest
. "$PSScriptRoot\CompletionReader.ps1"

$script:CompletionScanInterval = [TimeSpan]::FromSeconds(4)
$script:CompletionMaxFiles = 10000
$script:CompletionMaxDirectories = 20000
$script:CompletionMaxTurns = 65536
$script:CompletionMaxChunksPerFile = 4
$script:CompletionMaxChunksPerTick = 8

function Add-MonitorWarning($Monitor, [string]$Code, [string]$InstanceId, [string]$Path) {
    $key = $InstanceId + '|' + $Path + '|' + $Code
    if ($Monitor.WarningKeys.Add($key)) {
        $Monitor.Warnings.Add([pscustomobject]@{ Code = $Code; InstanceId = $InstanceId; Path = $Path })
    }
}

function Get-MonitorKey([string]$InstanceId, [string]$Path) {
    return $InstanceId.ToLowerInvariant() + '|' + [IO.Path]::GetFullPath($Path).ToLowerInvariant()
}

function Assert-MonitorStatePath([string]$StatePath, [string]$StateDirectory) {
    if ([string]::IsNullOrWhiteSpace($StateDirectory)) { throw 'Monitor requires a controller state directory.' }
    $root = [IO.Path]::GetFullPath($StateDirectory).TrimEnd('\')
    $path = [IO.Path]::GetFullPath($StatePath)
    if (-not $path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Monitor state must be inside the controller state directory.'
    }
    $part = $path
    while ($part) {
        try {
            if (([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Monitor state path contains a reparse point.'
            }
        } catch [IO.FileNotFoundException] {
        } catch [IO.DirectoryNotFoundException] {
        }
        $parent = [IO.Path]::GetDirectoryName($part)
        if (-not $parent -or $parent -eq $part) { break }
        $part = $parent
    }
    return $path
}

function Get-MonitorFiles($Monitor) {
    $found = New-Object 'System.Collections.Generic.List[object]'
    $directories = 0
    foreach ($instance in $Monitor.Instances) {
        $root = Join-Path $instance.Home 'sessions'
        if (-not [IO.Directory]::Exists($root)) { continue }
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($root)
        while ($stack.Count -gt 0) {
            $directory = $stack.Pop()
            $directories++
            if ($directories -gt $script:CompletionMaxDirectories) { throw 'MonitorDirectoryLimit' }
            try {
                if (([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                foreach ($child in [IO.Directory]::EnumerateDirectories($directory)) {
                    if (([IO.File]::GetAttributes($child) -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($child) }
                }
                foreach ($path in [IO.Directory]::EnumerateFiles($directory, '*.jsonl')) {
                    if (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $found.Add([pscustomobject]@{ InstanceId = $instance.Id; Path = $path })
                    if ($found.Count -gt $script:CompletionMaxFiles) { throw 'MonitorFileLimit' }
                }
            } catch {
                if ($_.Exception.Message -in @('MonitorDirectoryLimit', 'MonitorFileLimit')) { throw }
                Add-MonitorWarning $Monitor 'ScanError' $instance.Id $directory
            }
        }
    }
    return $found.ToArray()
}

function Save-CompletionMonitor($Monitor) {
    [void](Assert-MonitorStatePath $Monitor.StatePath $Monitor.StateDirectory)
    $state = [ordered]@{
        schema = 1
        instances = @($Monitor.Instances | ForEach-Object { [ordered]@{ id = $_.Id; home = $_.Home } })
        files = @($Monitor.Entries.Values | ForEach-Object {
            [ordered]@{ path = $_.Path; instanceId = $_.InstanceId; fileIdentity = $_.FileIdentity
                offset = $_.Offset; metaSeen = $_.MetaSeen; threadId = $_.ThreadId
                seenTurns = @($_.SeenTurns); status = $_.Status
                idleLength = $_.IdleLength; lastWriteTicks = $_.LastWriteTicks }
        })
    }
    $directory = [IO.Path]::GetDirectoryName($Monitor.StatePath)
    [void][IO.Directory]::CreateDirectory($directory)
    [void](Assert-MonitorStatePath $Monitor.StatePath $Monitor.StateDirectory)
    $temp = Join-Path $directory ([IO.Path]::GetFileName($Monitor.StatePath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = $temp + '.bak'
    try {
        [IO.File]::WriteAllText($temp, ($state | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Monitor.StatePath)) { [IO.File]::Replace($temp, $Monitor.StatePath, $backup) }
        else { [IO.File]::Move($temp, $Monitor.StatePath) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
}

function New-MonitorEntry($Monitor, $File, [bool]$Baseline) {
    $cursor = $null
    try {
        $cursor = New-CompletionCursor -Path $File.Path -InstanceId $File.InstanceId -FromStart:(-not $Baseline)
        $entry = [pscustomobject]@{
            Path = $cursor.Path; InstanceId = $cursor.InstanceId; FileIdentity = $cursor.FileIdentity
            Offset = [long]$cursor.Offset; MetaSeen = [bool]$cursor.MetaSeen; ThreadId = $cursor.ThreadId
            SeenTurns = @(); Status = $cursor.Status
            IdleLength = if ($Baseline) { [long]$cursor.Stream.Length } else { [long]-1 }
            LastWriteTicks = if ($Baseline) { [IO.File]::GetLastWriteTimeUtc($File.Path).Ticks } else { [long]0 }
        }
        if ($entry.Status -notin @('Ready','AwaitingMeta')) {
            Add-MonitorWarning $Monitor $entry.Status $entry.InstanceId $entry.Path
        }
        return $entry
    } catch {
        Add-MonitorWarning $Monitor 'ReadError' $File.InstanceId $File.Path
        return [pscustomobject]@{
            Path = $File.Path; InstanceId = $File.InstanceId; FileIdentity = ''; Offset = [long]0
            MetaSeen = $false; ThreadId = $null; SeenTurns = @(); Status = 'ReadError'
            IdleLength = [long]-1; LastWriteTicks = [long]0
        }
    } finally {
        if ($null -ne $cursor) { Close-CompletionCursor $cursor }
    }
}

function New-CompletionMonitor($Config, [string]$StatePath) {
    if ([string]::IsNullOrWhiteSpace($StatePath)) { throw 'Monitor state path is empty.' }
    $path = Assert-MonitorStatePath $StatePath ([string]$Config.stateDirectory)
    $instances = @($Config.instances | ForEach-Object {
        if ([string]$_.id -cnotmatch '^[0-9a-fA-F]{32}$' -or $_.role -notin @('official','api')) { throw 'Invalid monitor instance.' }
        [pscustomobject]@{ Id = ([string]$_.id).ToLowerInvariant(); Role = $_.role; Home = [IO.Path]::GetFullPath([string]$_.home) }
    })
    if ($instances.Count -ne 2 -or @($instances | Select-Object -ExpandProperty Id -Unique).Count -ne 2 -or
        @($instances | Select-Object -ExpandProperty Role -Unique).Count -ne 2 -or
        $instances[0].Home.Equals($instances[1].Home, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Monitor requires separate official and API homes.'
    }
    foreach ($instance in $instances) {
        if ($path.StartsWith($instance.Home.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Monitor state must be outside session homes.'
        }
    }
    $monitor = [pscustomobject]@{
        StatePath = $path; StateDirectory = [IO.Path]::GetFullPath([string]$Config.stateDirectory)
        Instances = $instances; Entries = @{}; NextScanUtc = [DateTime]::MinValue
        Warnings = (New-Object 'System.Collections.Generic.List[object]')
        WarningKeys = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))
        Delivered = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))
        Closed = $false
    }
    if ([IO.File]::Exists($path)) {
        $saved = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if ($saved.schema -ne 1 -or @($saved.instances).Count -ne 2) { throw 'Invalid monitor state.' }
        foreach ($instance in $instances) {
            $match = @($saved.instances | Where-Object { $_.id -eq $instance.Id -and $_.home -eq $instance.Home })
            if ($match.Count -ne 1) { throw 'Monitor state belongs to another environment.' }
        }
        foreach ($file in @($saved.files)) {
            if ($null -eq $file) { continue }
            $owner = @($instances | Where-Object { $_.Id -eq $file.instanceId })
            if ($owner.Count -ne 1 -or -not ([IO.Path]::GetFullPath([string]$file.path)).StartsWith(
                (Join-Path $owner[0].Home 'sessions').TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Invalid monitor file ownership.'
            }
            $entry = [pscustomobject]@{
                Path = [string]$file.path; InstanceId = [string]$file.instanceId; FileIdentity = [string]$file.fileIdentity
                Offset = [long]$file.offset; MetaSeen = [bool]$file.metaSeen; ThreadId = $file.threadId
                SeenTurns = @($file.seenTurns); Status = [string]$file.status
                IdleLength = [long]$file.idleLength; LastWriteTicks = [long]$file.lastWriteTicks
            }
            if ($entry.Offset -lt 0 -or $entry.SeenTurns.Count -gt $script:CompletionMaxTurns) { throw 'Invalid monitor state.' }
            $monitor.Entries[(Get-MonitorKey $entry.InstanceId $entry.Path)] = $entry
            if ($entry.ThreadId) {
                foreach ($turn in $entry.SeenTurns) {
                    [void]$monitor.Delivered.Add($entry.InstanceId + '|' + $entry.ThreadId + '|' + $turn)
                }
            }
            if ($entry.Status -notin @('Ready','AwaitingMeta')) {
                Add-MonitorWarning $monitor $entry.Status $entry.InstanceId $entry.Path
            }
        }
    } else {
        # A first enable records the complete history as read, including old day folders.
        foreach ($file in @(Get-MonitorFiles $monitor)) {
            $entry = New-MonitorEntry $monitor $file $true
            $monitor.Entries[(Get-MonitorKey $entry.InstanceId $entry.Path)] = $entry
        }
        Save-CompletionMonitor $monitor
    }
    $monitor.NextScanUtc = [DateTime]::UtcNow.Add($script:CompletionScanInterval)
    return $monitor
}

function Read-MonitorCompletions($Monitor) {
    if ($Monitor.Closed) { throw 'Monitor is closed.' }
    $changed = $false
    if ([DateTime]::UtcNow -ge $Monitor.NextScanUtc) {
        foreach ($file in @(Get-MonitorFiles $Monitor)) {
            $key = Get-MonitorKey $file.InstanceId $file.Path
            if (-not $Monitor.Entries.ContainsKey($key)) {
                $Monitor.Entries[$key] = New-MonitorEntry $Monitor $file $false
                $changed = $true
            }
        }
        $Monitor.NextScanUtc = [DateTime]::UtcNow.Add($script:CompletionScanInterval)
    }
    $events = New-Object 'System.Collections.Generic.List[object]'
    $chunksRemaining = $script:CompletionMaxChunksPerTick
    foreach ($entry in @($Monitor.Entries.Values)) {
        if ($chunksRemaining -le 0) { break }
        if ($entry.Status -notin @('Ready','AwaitingMeta')) { continue }
        try {
            $info = New-Object IO.FileInfo($entry.Path)
            if (-not $info.Exists) { continue }
            if ($info.Length -eq $entry.IdleLength -and
                $info.LastWriteTimeUtc.Ticks -eq $entry.LastWriteTicks) { continue }
            $cursor = $null
            try {
                $cursor = New-CompletionCursor -Path $entry.Path -InstanceId $entry.InstanceId
                if ($cursor.FileIdentity -ne $entry.FileIdentity) { $entry.Status = 'Replaced' }
                elseif ($info.Length -lt $entry.Offset) { $entry.Status = 'Truncated' }
                else {
                    $cursor.Offset = $entry.Offset
                    $cursor.MetaSeen = $entry.MetaSeen
                    $cursor.ThreadId = $entry.ThreadId
                    $cursor.Status = $entry.Status
                    foreach ($turn in $entry.SeenTurns) { [void]$cursor.SeenTurns.Add([string]$turn) }
                    $fileEvents = New-Object 'System.Collections.Generic.List[object]'
                    for ($chunk = 0; $chunk -lt $script:CompletionMaxChunksPerFile -and $chunksRemaining -gt 0; $chunk++) {
                        $before = $cursor.Offset
                        $read = Read-NewCompletions $cursor
                        $chunksRemaining--
                        if ($read.Status -notin @('Ready','AwaitingMeta')) { break }
                        foreach ($completion in $read.Completions) { $fileEvents.Add($completion) }
                        if ($cursor.Offset -eq $before -or $cursor.Offset -eq $cursor.Stream.Length) { break }
                    }
                    # Persist the start of a partial line, not an unpersisted byte buffer.
                    $entry.Offset = $cursor.Offset - $cursor.Pending.Length
                    $entry.MetaSeen = $cursor.MetaSeen
                    $entry.ThreadId = $cursor.ThreadId
                    $entry.SeenTurns = @($cursor.SeenTurns)
                    $entry.Status = $cursor.Status
                    $entry.IdleLength = if ($cursor.Offset -eq $cursor.Stream.Length) { [long]$cursor.Stream.Length } else { [long]-1 }
                    $entry.LastWriteTicks = $info.LastWriteTimeUtc.Ticks
                    if ($entry.SeenTurns.Count -gt $script:CompletionMaxTurns) { $entry.Status = 'TurnLimit' }
                    if ($entry.Status -eq 'Ready') {
                        foreach ($completion in $fileEvents) {
                            $eventKey = $completion.InstanceId + '|' + $completion.ThreadId + '|' + $completion.TurnId
                            if ($Monitor.Delivered.Add($eventKey)) { $events.Add($completion) }
                        }
                    }
                }
            } finally {
                if ($null -ne $cursor) { Close-CompletionCursor $cursor }
            }
        } catch {
            $entry.Status = if ($_.Exception.Message -like '*reparse point*') { 'InvalidPath' } else { 'ReadError' }
        }
        if ($entry.Status -notin @('Ready','AwaitingMeta')) {
            Add-MonitorWarning $Monitor $entry.Status $entry.InstanceId $entry.Path
        }
        $changed = $true
    }
    if ($changed) { Save-CompletionMonitor $Monitor }
    return $events.ToArray()
}

function Close-CompletionMonitor($Monitor) { $Monitor.Closed = $true }
