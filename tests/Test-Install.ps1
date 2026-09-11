$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('install-'+[Guid]::NewGuid().ToString('N'))
$install=Join-Path $root 'Tool';$data=Join-Path $root 'Data';$official=Join-Path $root 'Official';$links=Join-Path $root 'Links'
[void][IO.Directory]::CreateDirectory($root)
$fake=ConvertTo-SecureString 'fixture-not-a-key' -AsPlainText -Force
$exe="$env:SystemRoot\System32\notepad.exe"
& "$PSScriptRoot\..\scripts\Install.ps1" -InstallDirectory $install -DataDirectory $data -OfficialHome $official -Executable $exe -BaseUrl 'https://example.com/v1' -Model 'fixture' -ApiKey $fake -ShortcutDirectory $links
function Check($value,$name){if(-not $value){throw "FAIL: $name"};Write-Output "PASS: $name"}
$configPath=Join-Path $install 'instances.local.json';$before=(Get-FileHash -LiteralPath $configPath).Hash
Check (Test-Path -LiteralPath "$install\src\Controller.ps1") 'Controller installed'
Check (@(Get-ChildItem -LiteralPath $links -Filter *.lnk).Count -eq 3) 'Three shortcuts created'
$shell=New-Object -ComObject WScript.Shell
$linkFile=@(Get-ChildItem -LiteralPath $links -Filter *.lnk)[0]
$moved=Join-Path $root 'Moved.lnk';Move-Item -LiteralPath $linkFile.FullName -Destination $moved
$shortcut=$shell.CreateShortcut($moved)
Check ($shortcut.Arguments.Contains($install) -and $shortcut.WorkingDirectory -eq $install) 'Moved shortcut still uses fixed absolute controller/config paths'
Check ($shortcut.IconLocation.StartsWith($install) -and -not $shortcut.IconLocation.Contains('WindowsApps')) 'Icon independent of versioned program path'
& "$PSScriptRoot\..\scripts\Install.ps1" -InstallDirectory $install
Check ((Get-FileHash -LiteralPath $configPath).Hash -eq $before) 'Repeated install preserves configuration'
$sentinel=Join-Path $data 'keep-user-data.txt';[IO.File]::WriteAllText($sentinel,'keep')
$keyHash=(Get-FileHash -LiteralPath "$data\API\Credentials\api-key.dpapi").Hash
& "$install\scripts\Uninstall.ps1"
Check (Test-Path -LiteralPath $sentinel) 'Uninstall preserves user data'
Check ((Get-FileHash -LiteralPath "$data\API\Credentials\api-key.dpapi").Hash -eq $keyHash) 'Uninstall preserves encrypted credential'
Check (Test-Path -LiteralPath "$official\config.toml") 'Uninstall preserves official configuration'
Check (-not (Test-Path -LiteralPath "$install\src\Controller.ps1")) 'Uninstall removes controller executable script'
Check (Test-Path -LiteralPath $moved) 'Moved shortcut deliberately retained for manual removal'
Check (Test-Path -LiteralPath $configPath) 'Recovery configuration retained'
Write-Output 'PASSED: 11 deployment checks'
