$ErrorActionPreference='Stop'
function Read-DotNetPackage([string]$Package){
    $Package=[IO.Path]::GetFullPath($Package).TrimEnd('\')
    $manifest=Get-Content -LiteralPath (Join-Path $Package 'dotnet-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if($manifest.schema -ne 1 -or @($manifest.files).Count -lt 3){throw 'Invalid C# package manifest.'}
    $seen=@{}
    foreach($entry in $manifest.files){
        $relative=[string]$entry.path
        if(-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or $relative -match '(^|[\\/])\.\.?([\\/]|$)' -or $relative -match '(^|[\\/])(state|sessions|Credentials|CodexHome|DesktopProfile|backups|upgrades)([\\/]|$)' -or $relative -match '(^|[\\/])(auth\.json|instances\.local\.json|install-manifest\.json|dotnet-manifest\.json)$' -or $seen.ContainsKey($relative.Replace('/','\'))){throw 'Invalid or duplicate package path.'}
        $seen[$relative.Replace('/','\')]=$true
        $path=[IO.Path]::GetFullPath((Join-Path $Package $relative))
        if(-not $path.StartsWith($Package+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Package path escaped root.'}
        for($parent=$path;$parent;$parent=[IO.Path]::GetDirectoryName($parent)){if((Test-Path -LiteralPath $parent) -and ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Package contains a reparse path.'}}
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256){throw ('Package checksum mismatch: '+$relative)}
    }
    foreach($required in @('CodexDualController.exe','CodexDualController.dll','CodexDual.Core.dll','version.json')){if(-not $seen.ContainsKey($required)){throw ('Missing package file: '+$required)}}
    $version=Get-Content -LiteralPath (Join-Path $Package 'version.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if($version.product -ne 'codex-desktop-dual-environment' -or $manifest.version -ne $version.version){throw 'Package version mismatch.'}
    return $manifest
}
