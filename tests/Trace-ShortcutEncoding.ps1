# Diagnostic only: create inert shortcuts in a unique test directory; never launch them.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class ShortcutEncodingProbe {
    [DllImport("kernel32.dll")] public static extern uint GetACP();
}
'@
Write-Output ('Shortcut diagnostic: ACP=' + [ShortcutEncodingProbe]::GetACP() + '; culture=' + [Globalization.CultureInfo]::CurrentCulture.Name)
$root = Join-Path $PSScriptRoot ('..\test-results\shortcut-encoding-' + [Guid]::NewGuid().ToString('N'))
$root = [IO.Path]::GetFullPath($root)
[void][IO.Directory]::CreateDirectory($root)
$unicodeName = 'Codex ' + [char]0x5b98 + [char]0x65b9
$unicodeDirectory = Join-Path $root ([string][char]0x4e2d + [char]0x6587)
[void][IO.Directory]::CreateDirectory($unicodeDirectory)
$shell = New-Object -ComObject WScript.Shell
foreach ($case in @(
    @{ Name='ascii'; Directory=$root; File='ascii.lnk' },
    @{ Name='unicode-filename'; Directory=$root; File=($unicodeName + '.lnk') },
    @{ Name='unicode-directory'; Directory=$unicodeDirectory; File='ascii.lnk' }
)) {
    $path = Join-Path $case.Directory $case.File
    # Establish that the directory and filename are writable independently of WSH.
    [IO.File]::WriteAllText($path + '.txt', 'diagnostic fixture')
    try {
        $link = $shell.CreateShortcut($path)
        $link.TargetPath = "$env:SystemRoot\System32\notepad.exe"
        $link.Save()
        Write-Output ('Shortcut diagnostic: ' + $case.Name + '; Save=success; exactFileExists=' + [IO.File]::Exists($path))
    } catch {
        Write-Warning ('Shortcut diagnostic: ' + $case.Name + '; Save=failed; type=' + $_.Exception.GetType().FullName + '; message=' + $_.Exception.Message)
    }
}
