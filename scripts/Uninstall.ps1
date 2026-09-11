param([string]$InstallDirectory=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Core.ps1"
$root=Get-FullDirectory $InstallDirectory;Assert-NoReparsePoint $root
$manifestPath=Join-Path $root 'install-manifest.json'
$manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if($manifest.schema -ne 1 -or -not (Test-PathOverlap $root $manifest.root) -or $root -ne $manifest.root){throw '安装记录与目标目录不符。'}
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex=New-Object Threading.Mutex($false,('Local\CodexDual.Controller.'+$sid));$held=$false
try {
    try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not $held){throw '请先从托盘退出控制器。Codex 不需要退出。'}
    $remove=@();$preserved=@()
    # Resolve and validate EVERY file before deleting any file. No recursive deletion.
    foreach($entry in $manifest.files){
        if([IO.Path]::IsPathRooted($entry.path)){throw '清单包含非法绝对路径。'}
        $path=[IO.Path]::GetFullPath((Join-Path $root $entry.path))
        if(-not $path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw '清单路径越出工具目录。'}
        Assert-NoReparsePoint $path
        if(Test-Path -LiteralPath $path){if((Get-FileHash -LiteralPath $path).Hash -eq $entry.sha256){$remove+=$path}else{$preserved+=$path}}
    }
    foreach($entry in $manifest.shortcuts){
        $path=Get-FullDirectory $entry.path;Assert-NoReparsePoint $path
        if([IO.Path]::GetExtension($path) -ne '.lnk'){throw '非法快捷方式清单。'}
        if(Test-Path -LiteralPath $path){if((Get-FileHash -LiteralPath $path).Hash -eq $entry.sha256){$remove+=$path}else{$preserved+=$path}}
    }
    foreach($path in $remove){Remove-Item -LiteralPath $path -Force}
    Write-Output '工具文件及原位置未修改的快捷方式已移除。两套用户数据、密钥、本机配置、运行记录及修改过的文件全部保留。'
    Write-Output '移动过的快捷方式请手动删除；不会搜索或删除收纳应用里的文件。'
    if($preserved.Count){Write-Output ('保留修改过的文件：'+$preserved.Count)}
}finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
