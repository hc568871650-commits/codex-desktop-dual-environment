param(
 [Parameter(Mandatory)][string]$Package,
 [Parameter(Mandatory)][string]$Target,
 [Parameter(Mandatory)][string]$Backup,
 [string]$ApiLauncher='',
 [string]$TitleModel='gpt-6-luna',
 [string]$CredentialVariable='',
 [string]$CredentialFile='',
 [switch]$Apply
)
$ErrorActionPreference='Stop'
function Plain([string]$Path){
 $full=[IO.Path]::GetFullPath($Path)
 if($full.StartsWith('\\') -or $full.Length -le 3){throw 'Expected a local non-root path.'}
 for($p=$full;$p;$p=[IO.Path]::GetDirectoryName($p)){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse paths are not supported.'}}
 return $full.TrimEnd('\')
}
function Atomic([string]$Path,[byte[]]$Bytes){
 [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent));$temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{[IO.File]::WriteAllBytes($temp,$Bytes);if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}}finally{if(Test-Path -LiteralPath $temp){[IO.File]::Delete($temp)}}
}
$Package=Plain $Package;$Target=Plain $Target;$Backup=Plain $Backup
foreach($pair in @(@($Package,$Target),@($Package,$Backup),@($Target,$Backup))){if($pair[0] -eq $pair[1] -or $pair[0].StartsWith($pair[1]+'\',[StringComparison]::OrdinalIgnoreCase) -or $pair[1].StartsWith($pair[0]+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Package, installation and backup must be separate.'}}
if(Test-Path -LiteralPath $Backup){throw 'Backup directory must be new.'}
$configPath=Join-Path $Target 'instances.local.json';$config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json
if($config.schema -ne 1 -or @($config.instances).Count -ne 2){throw 'Existing instance configuration required.'}
$api=@($config.instances|Where-Object {$_.role -eq 'api'});if($api.Count -ne 1){throw 'Exactly one API environment required.'}
. "$PSScriptRoot\DotNet-Package.ps1"
$manifest=Read-DotNetPackage $Package
if($manifest.schema -ne 1){throw 'Invalid package manifest.'}
$entries=@();$seen=@{}
foreach($entry in @($manifest.files)){
 $relative=[string]$entry.path
 if([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)' -or $relative -match '^(state|CodexHome|Credentials)[\\/]' -or $relative -eq 'instances.local.json' -or $seen.ContainsKey($relative.ToLowerInvariant())){throw 'Invalid package path.'}
 $seen[$relative.ToLowerInvariant()]=$true;$source=Plain (Join-Path $Package $relative);$destination=Plain (Join-Path $Target $relative)
 if(-not $destination.StartsWith($Target+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Destination outside installation.'}
 if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.sha256){throw 'Package checksum mismatch.'}
 $exists=Test-Path -LiteralPath $destination
 $entries+=@{path=$relative;beforeExists=$exists;beforeHash=if($exists){(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash}else{''};afterHash=$entry.sha256}
}
if(-not $seen.ContainsKey('codexdualcontroller.exe') -or -not $seen.ContainsKey('codexdualcontroller.dll') -or -not $seen.ContainsKey('codexdual.core.dll')){throw 'Missing controller binaries.'}
$manifestTarget=Join-Path $Target 'dotnet-manifest.json';$manifestExists=Test-Path -LiteralPath $manifestTarget
$entries+=@{path='dotnet-manifest.json';beforeExists=$manifestExists;beforeHash=if($manifestExists){(Get-FileHash -LiteralPath $manifestTarget -Algorithm SHA256).Hash}else{''};afterHash=(Get-FileHash -LiteralPath (Join-Path $Package 'dotnet-manifest.json') -Algorithm SHA256).Hash}
$ownershipPath=Join-Path $Target 'install-manifest.json'
$owned=if(Test-Path -LiteralPath $ownershipPath){Get-Content -LiteralPath $ownershipPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
if($owned -and ($owned.schema -ne 1 -or [IO.Path]::GetFullPath($owned.root).TrimEnd('\') -ne $Target)){throw 'Installation manifest belongs to another directory.'}
$ownership=@{schema=1;root=$Target;version=$manifest.version;files=@();shortcuts=@();retainedData=@($config.instances.home);created=[DateTimeOffset]::UtcNow.ToString('o')}
if($owned){$ownership.shortcuts=@($owned.shortcuts);$ownership.files=@($owned.files|Where-Object {$_.path -notin @($entries.path)})}
$ownership.files+=@($entries|ForEach-Object {@{path=$_.path;sha256=$_.afterHash}})
$ownershipBytes=[Text.Encoding]::UTF8.GetBytes(($ownership|ConvertTo-Json -Depth 8))
$sha=[Security.Cryptography.SHA256]::Create();try{$ownershipHash=([BitConverter]::ToString($sha.ComputeHash($ownershipBytes))).Replace('-','')}finally{$sha.Dispose()}
$entries+=@{path='install-manifest.json';beforeExists=[bool]$owned;beforeHash=if($owned){(Get-FileHash -LiteralPath $ownershipPath).Hash}else{''};afterHash=$ownershipHash}
$exe=Join-Path $Target 'CodexDualController.exe'
$launcherBefore=$null;$launcherAfter=$null;$oldBlock=$null;$newBlock=$null
if($ApiLauncher){
 $ApiLauncher=Plain $ApiLauncher
 if($api[0].launchMode -ne 'external' -or [IO.Path]::GetFullPath($api[0].externalLauncher) -ne $ApiLauncher){throw 'Launcher is not registered to the API instance.'}
 $launcherBefore=[IO.File]::ReadAllText($ApiLauncher)
 $pattern='(?ms)^[ \t]*# BEGIN CODEX NATIVE TITLE v1\r?\n.*?^[ \t]*# END CODEX NATIVE TITLE v1'
 $matches=[regex]::Matches($launcherBefore,$pattern);if($matches.Count -ne 1){throw 'Expected one original title integration block.'}
 $oldBlock=$matches[0].Value
 $escapedExe=$exe.Replace("'","''");$escapedConfig=$configPath.Replace("'","''");$escapedState=([string]$config.stateDirectory).Replace("'","''")
 $newBlock=@'
        # BEGIN CODEX NATIVE TITLE v1
        # C# title adapter: discover current Desktop/CLI at runtime; no version-pinned Node/Python.
        $titleArguments = @()
        $titleController = '__EXE__'
        $titleConfig = '__CONFIG__'
        try {
            $titleOwner = Get-Content -LiteralPath $titleConfig -Raw -Encoding UTF8 | ConvertFrom-Json
            $titleApi = @($titleOwner.instances | Where-Object { $_.role -eq 'api' })
            if ($titleApi.Count -ne 1 -or [IO.Path]::GetFullPath($titleApi[0].home) -ne [IO.Path]::GetFullPath($apiCodexHome) -or [IO.Path]::GetFullPath($titleApi[0].profile) -ne [IO.Path]::GetFullPath($apiDesktopProfile)) { throw 'title-instance-mismatch' }
            $titleManifest = Get-Content -LiteralPath (Join-Path (Split-Path $titleController -Parent) 'dotnet-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($name in @('CodexDualController.exe','CodexDualController.dll','CodexDual.Core.dll')) {
                $file = Join-Path (Split-Path $titleController -Parent) $name
                $pin = @($titleManifest.files | Where-Object { $_.path -eq $name })
                if ($pin.Count -ne 1 -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $pin[0].sha256) { throw 'title-controller-integrity-failed' }
            }
            $titleSettingsPath = Join-Path $titleOwner.stateDirectory 'dotnet-title.local.json'
            $titleEnabled = $false
            if (Test-Path -LiteralPath $titleSettingsPath) { $titleEnabled = (Get-Content -LiteralPath $titleSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json).enabled -eq $true }
            if ($titleEnabled) { $titleArguments = @('--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1') }
        } catch {
            Write-LauncherLog 'C# title startup validation failed; check controller diagnostics.'
            @{component='title-startup';state='failed';reason='controller-or-instance-validation';checkedAt=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath '__STATE__\title-startup.local.json' -Encoding UTF8
        }
        Start-Process -FilePath $codexDesktopExe -ArgumentList (@("--user-data-dir=$apiDesktopProfile") + $titleArguments) -WorkingDirectory (Join-Path $apiRoot "Projects")
        if ($titleArguments.Count -gt 0) {
            Start-Process -FilePath $titleController -ArgumentList ('--background --config "' + $titleConfig + '"') -WindowStyle Hidden
            Write-LauncherLog 'C# title adapter enabled for this API launch; runtime compatibility is checked automatically.'
        }
        # END CODEX NATIVE TITLE v1
'@
 $newBlock=$newBlock.Replace('__EXE__',$escapedExe).Replace('__CONFIG__',$escapedConfig).Replace('__STATE__',$escapedState)
 if($launcherBefore.Contains("`r`n")){$newBlock=$newBlock.Replace("`r`n","`n").Replace("`n","`r`n")}
 $launcherAfter=$launcherBefore.Substring(0,$matches[0].Index)+$newBlock+$launcherBefore.Substring($matches[0].Index+$matches[0].Length)
}
$running=@(Get-CimInstance Win32_Process -Filter "Name='CodexDualController.exe'"|Where-Object {$_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -eq $exe})
$protected=@($configPath,(Join-Path $api[0].home 'config.toml'),(Join-Path $api[0].home 'auth.json'))
if($CredentialFile){$CredentialFile=Plain $CredentialFile;$protected+=$CredentialFile}
$hashes=@{};foreach($path in $protected){$hashes[$path]=if(Test-Path -LiteralPath $path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}else{'<absent>'}}
$plan=@{schema=1;package=$Package;target=$Target;backup=$Backup;config=$configPath;files=$entries;launcher=$ApiLauncher;originalTitleBlock=$oldBlock;installedTitleBlock=$newBlock;protectedHashes=$hashes;controllerProcesses=@($running|Select-Object ProcessId,CreationDate);applied=$false;titleSettingsPath=(Join-Path $config.stateDirectory 'dotnet-title.local.json')}
if(-not $Apply){[pscustomobject]$plan|Select-Object schema,package,target,backup,launcher,controllerProcesses|ConvertTo-Json -Depth 5;return}
[void][IO.Directory]::CreateDirectory($Backup)
foreach($entry in $entries){if($entry.beforeExists){$copy=Join-Path $Backup ('files\'+$entry.path);[void][IO.Directory]::CreateDirectory((Split-Path $copy -Parent));[IO.File]::Copy((Join-Path $Target $entry.path),$copy,$false)}}
if($ApiLauncher){[IO.File]::WriteAllText((Join-Path $Backup 'launcher.original.ps1'),$launcherBefore,(New-Object Text.UTF8Encoding($true)))}
$settingsPath=$plan.titleSettingsPath
if(Test-Path -LiteralPath $settingsPath){[IO.File]::Copy($settingsPath,(Join-Path $Backup 'title-settings.original.json'),$false)}
$plan|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $Backup 'receipt.json') -Encoding UTF8
try{
 foreach($entry in $running){$p=Get-Process -Id $entry.ProcessId -ErrorAction SilentlyContinue;if($p){try{if([math]::Abs($p.StartTime.ToUniversalTime().Ticks-$entry.CreationDate.ToUniversalTime().Ticks) -ge 10){throw 'Controller PID reused.'};if([IO.Path]::GetFullPath($p.MainModule.FileName) -ne $exe){throw 'Controller identity changed.'};$p.Kill();[void]$p.WaitForExit(5000)}finally{$p.Dispose()}}}
 foreach($entry in $entries){$bytes=if($entry.path -eq 'install-manifest.json'){$ownershipBytes}else{[IO.File]::ReadAllBytes((Join-Path $Package $entry.path))};Atomic (Join-Path $Target $entry.path) $bytes}
 if(-not(Test-Path -LiteralPath $settingsPath)){
  $credentials=@{};if($CredentialVariable -and $CredentialFile){$credentials[$CredentialVariable]=$CredentialFile}
  $settings=@{schema=1;enabled=$false;model=$TitleModel;transport='codex-cli';credentialFiles=$credentials}
  Atomic $settingsPath ([Text.Encoding]::UTF8.GetBytes(($settings|ConvertTo-Json -Depth 4)))
 }
 if($ApiLauncher){Atomic $ApiLauncher ((New-Object Text.UTF8Encoding($true)).GetPreamble()+[Text.Encoding]::UTF8.GetBytes($launcherAfter))}
 foreach($path in $protected){$after=if(Test-Path -LiteralPath $path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}else{'<absent>'};if($after -ne $hashes[$path]){throw 'Protected file changed during installation.'}}
 foreach($entry in $entries){if((Get-FileHash -LiteralPath (Join-Path $Target $entry.path) -Algorithm SHA256).Hash -ne $entry.afterHash){throw 'Installed checksum mismatch.'}}
 $plan.titleSettingsAfterHash=(Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
 $plan.applied=$true;$plan.appliedAt=[DateTimeOffset]::UtcNow.ToString('o');$plan|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $Backup 'receipt.json') -Encoding UTF8
 Write-Output (Join-Path $Backup 'receipt.json')
}catch{
 foreach($entry in $entries){$path=Join-Path $Target $entry.path;if($entry.beforeExists){Atomic $path ([IO.File]::ReadAllBytes((Join-Path $Backup ('files\'+$entry.path))))}elseif(Test-Path -LiteralPath $path){[IO.File]::Delete($path)}}
 if($ApiLauncher){Atomic $ApiLauncher ((New-Object Text.UTF8Encoding($true)).GetPreamble()+[Text.Encoding]::UTF8.GetBytes($launcherBefore))}
 if(Test-Path -LiteralPath (Join-Path $Backup 'title-settings.original.json')){Atomic $settingsPath ([IO.File]::ReadAllBytes((Join-Path $Backup 'title-settings.original.json')))}
 elseif(Test-Path -LiteralPath $settingsPath){[IO.File]::Delete($settingsPath)}
 if($running.Count){Start-Process -FilePath $exe -ArgumentList ('--background --config "'+$configPath+'"') -WindowStyle Hidden}
 throw
}
