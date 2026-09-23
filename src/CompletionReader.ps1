Set-StrictMode -Version Latest

if (-not ('CodexDual.CompletionFileIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace CodexDual {
    public static class CompletionFileIdentity {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInfo {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Created;
            public System.Runtime.InteropServices.ComTypes.FILETIME Accessed;
            public System.Runtime.InteropServices.ComTypes.FILETIME Written;
            public uint Volume;
            public uint SizeHigh;
            public uint SizeLow;
            public uint Links;
            public uint IndexHigh;
            public uint IndexLow;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);
        public static string Of(FileStream stream) {
            FileInfo info;
            if (!GetFileInformationByHandle(stream.SafeFileHandle, out info))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return info.Volume.ToString("X8") + ":" + info.IndexHigh.ToString("X8") + info.IndexLow.ToString("X8");
        }
    }
}
'@
}

$script:CompletionEncoding = New-Object System.Text.UTF8Encoding($false, $true)
$script:CompletionReadLimit = 1048576
$script:CompletionLineLimit = 2097152

function Assert-CompletionPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Completion log path is empty.' }
    $full = [IO.Path]::GetFullPath($Path)
    $part = $full
    while ($part) {
        if (([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Completion log path contains a reparse point.'
        }
        $parent = [IO.Path]::GetDirectoryName($part)
        if (-not $parent -or $parent -eq $part) { break }
        $part = $parent
    }
    return $full
}

function Test-CompletionUuid($Value) {
    return $Value -is [string] -and $Value -cmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

function Get-CompletionProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-CompletionLine($Cursor, [byte[]]$Bytes) {
    try {
        $item = ConvertFrom-Json -InputObject $script:CompletionEncoding.GetString($Bytes).TrimEnd([char]13) -ErrorAction Stop
    } catch {
        if (-not $Cursor.MetaSeen) { $Cursor.Status = 'InvalidMeta' }
        else { $Cursor.Status = 'InvalidJson' }
        return $null
    }
    if (-not $Cursor.MetaSeen) {
        $meta = Get-CompletionProperty $item 'payload'
        $source = Get-CompletionProperty $meta 'source'
        $id = Get-CompletionProperty $meta 'id'
        if ((Get-CompletionProperty $item 'type') -cne 'session_meta' -or -not (Test-CompletionUuid $id) -or
            $source -isnot [string] -or $source -cne 'vscode' -or
            (Get-CompletionProperty $meta 'originator') -cne 'Codex Desktop' -or
            (Get-CompletionProperty $meta 'parent_thread_id') -or
            (Get-CompletionProperty $meta 'thread_source') -eq 'subagent' -or
            (Get-CompletionProperty $meta 'agent_path')) {
            $Cursor.Status = 'InvalidMeta'
            return $null
        }
        $Cursor.ThreadId = ([guid]$id).ToString()
        $Cursor.MetaSeen = $true
        $Cursor.Status = 'Ready'
        return $null
    }
    if ((Get-CompletionProperty $item 'type') -cne 'event_msg') { return $null }
    $payload = Get-CompletionProperty $item 'payload'
    if ((Get-CompletionProperty $payload 'type') -cne 'task_complete') { return $null }
    $turnId = Get-CompletionProperty $payload 'turn_id'
    if (-not (Test-CompletionUuid $turnId)) { $Cursor.SkippedLines++; return $null }
    $normalized = ([guid]$turnId).ToString()
    if (-not $Cursor.SeenTurns.Add($normalized)) { return $null }
    return [pscustomobject]@{ InstanceId = $Cursor.InstanceId; ThreadId = $Cursor.ThreadId; TurnId = $normalized }
}

function Read-CompletionMeta($Cursor) {
    # Only the first line is needed to establish ownership of historical files.
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    $Cursor.Stream.Position = 0
    while ($bytes.Count -le $script:CompletionLineLimit) {
        $value = $Cursor.Stream.ReadByte()
        if ($value -lt 0) { return }
        if ($value -eq 10) {
            [void](Read-CompletionLine $Cursor $bytes.ToArray())
            return
        }
        $bytes.Add([byte]$value)
    }
    $Cursor.Status = 'InvalidMeta'
}

function New-CompletionCursor([string]$Path, [string]$InstanceId, [switch]$FromStart) {
    if ($InstanceId -cnotmatch '^[0-9a-fA-F]{32}$') { throw 'Invalid instance ID.' }
    $full = Assert-CompletionPath $Path
    $stream = New-Object IO.FileStream($full, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $cursor = [pscustomobject]@{
            Path = $full; InstanceId = $InstanceId.ToLowerInvariant(); Stream = $stream
            FileIdentity = [CodexDual.CompletionFileIdentity]::Of($stream)
            Offset = [long]0; Pending = [byte[]]@(); MetaSeen = $false; ThreadId = $null
            SeenTurns = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            SkippedLines = 0; Status = 'AwaitingMeta'
        }
        if (-not $FromStart -and $stream.Length -gt 0) {
            Read-CompletionMeta $cursor
            if ($cursor.MetaSeen) { $cursor.Offset = $stream.Length }
        }
        return $cursor
    } catch {
        $stream.Dispose()
        throw
    }
}

function Read-NewCompletions($Cursor) {
    $events = New-Object 'System.Collections.Generic.List[object]'
    if ($Cursor.Status -in @('InvalidMeta', 'InvalidJson', 'LineTooLong', 'Truncated', 'Replaced', 'InvalidPath', 'ReadError', 'Closed')) {
        return [pscustomobject]@{ Status = $Cursor.Status; Completions = @(); SkippedLines = $Cursor.SkippedLines }
    }
    try {
        $path = Assert-CompletionPath $Cursor.Path
        $probe = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $identity = [CodexDual.CompletionFileIdentity]::Of($probe) }
        finally { $probe.Dispose() }
        if ($identity -ne $Cursor.FileIdentity) { $Cursor.Status = 'Replaced' }
        elseif ($Cursor.Stream.Length -lt $Cursor.Offset) { $Cursor.Status = 'Truncated' }
        if ($Cursor.Status -in @('Replaced', 'Truncated')) {
            return [pscustomobject]@{ Status = $Cursor.Status; Completions = @(); SkippedLines = $Cursor.SkippedLines }
        }
        $remaining = [int][Math]::Min($script:CompletionReadLimit, $Cursor.Stream.Length - $Cursor.Offset)
        $buffer = New-Object byte[] $remaining
        $Cursor.Stream.Position = $Cursor.Offset
        $count = $Cursor.Stream.Read($buffer, 0, $remaining)
        $Cursor.Offset += $count
        $lineStart = 0
        for ($i = 0; $i -lt $count; $i++) {
            if ($buffer[$i] -ne 10) { continue }
            $length = $i - $lineStart
            $lineBytes = New-Object byte[] ($Cursor.Pending.Length + $length)
            [Array]::Copy($Cursor.Pending, 0, $lineBytes, 0, $Cursor.Pending.Length)
            [Array]::Copy($buffer, $lineStart, $lineBytes, $Cursor.Pending.Length, $length)
            $Cursor.Pending = [byte[]]@()
            $lineStart = $i + 1
            if ($lineBytes.Length -gt $script:CompletionLineLimit) {
                $Cursor.Status = if ($Cursor.MetaSeen) { 'LineTooLong' } else { 'InvalidMeta' }
            } else {
                $event = Read-CompletionLine $Cursor $lineBytes
                if ($null -ne $event) { $events.Add($event) }
            }
            if ($Cursor.Status -in @('InvalidMeta', 'InvalidJson', 'LineTooLong')) { break }
        }
        if ($Cursor.Status -notin @('InvalidMeta', 'InvalidJson', 'LineTooLong') -and $lineStart -lt $count) {
            $tailLength = $count - $lineStart
            $tail = New-Object byte[] ($Cursor.Pending.Length + $tailLength)
            [Array]::Copy($Cursor.Pending, 0, $tail, 0, $Cursor.Pending.Length)
            [Array]::Copy($buffer, $lineStart, $tail, $Cursor.Pending.Length, $tailLength)
            $Cursor.Pending = $tail
            if ($tail.Length -gt $script:CompletionLineLimit) {
                $Cursor.Status = if ($Cursor.MetaSeen) { 'LineTooLong' } else { 'InvalidMeta' }
            }
        }
    } catch {
        $Cursor.Status = if ($_.Exception.Message -like '*reparse point*') { 'InvalidPath' } else { 'ReadError' }
    }
    if ($Cursor.Status -ne 'Ready') { $events.Clear() }
    return [pscustomobject]@{ Status = $Cursor.Status; Completions = @($events.ToArray()); SkippedLines = $Cursor.SkippedLines }
}

function Close-CompletionCursor($Cursor) {
    if ($Cursor.Stream) { $Cursor.Stream.Dispose(); $Cursor.Stream = $null }
    $Cursor.Status = 'Closed'
}
