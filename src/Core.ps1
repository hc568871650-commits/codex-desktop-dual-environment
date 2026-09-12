Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ProductId = 'codex-desktop-dual-environment/v1'
if (-not ('CodexDual.TomlConfig' -as [type])) { Add-Type -Path "$PSScriptRoot\TomlConfig.cs" }

function Get-ApiManagementMode([string]$Root) {
    $path=Join-Path $Root '.codex-dual.json'
    if(Test-Path -LiteralPath $path){
        Assert-NoReparsePoint $path
        $meta=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if($meta.PSObject.Properties['managementMode']){return [string]$meta.managementMode}
    }
    return 'builtin'
}
function Read-ApiAuth([string]$Path) {
    try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}
    catch{throw '无法读取 API 认证文件，请检查文件存在且为有效 JSON；未输出认证内容。'}
}

function Merge-ApiConfig([string]$Text,[string]$Root,[string]$BaseUrl,[string]$Model) {
    # Validate input before touching the source. Each edit preserves all other text.
    [void](New-ApiConfig $Root $BaseUrl $Model)
    $initial=New-Object CodexDual.TomlConfig($Text)
    $provider=$initial.GetString('model_provider')
    if($provider -and $provider -ne 'dual-api'){throw '当前配置已选择其他服务商，请先核对管理方式；内置管理不会直接覆盖外部服务商。'}
    if($initial.HasPrefix('model_providers.dual-api.auth') -or $initial.HasPrefix('model_providers.dual-api.experimental_bearer_token')){throw '受管理服务商存在其他认证配置，请先处理冲突。'}
    $fields=[ordered]@{
        forced_login_method='"api"';cli_auth_credentials_store='"file"';model_provider='"dual-api"';model=(ConvertTo-TomlString $Model.Trim())
        'model_providers.dual-api.name'='"API Environment"';'model_providers.dual-api.base_url'=(ConvertTo-TomlString $BaseUrl.Trim().TrimEnd('/'))
        'model_providers.dual-api.wire_api'='"responses"';'model_providers.dual-api.requires_openai_auth'='false';'model_providers.dual-api.env_key'='"CODEX_DUAL_API_KEY"'
        'desktop.projectlessWorkspaceRoot'=(ConvertTo-TomlString (Join-Path $Root 'Projectless'))
    }
    foreach($field in $fields.Keys){$document=New-Object CodexDual.TomlConfig($Text);$Text=$document.Set($field,$fields[$field])}
    return $Text
}

function Write-AtomicBytes([string]$Path,[byte[]]$Bytes) {
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllBytes($temporary,$Bytes)
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
    }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
}

function Write-ApiTransaction([string]$Root,[System.Collections.IDictionary]$Changes) {
    $allowed=@('CodexHome\config.toml','CodexHome\auth.json','Credentials\api-key.dpapi','.codex-dual.json','api-providers.local.json')
    $before=@{};$written=New-Object 'Collections.Generic.List[string]'
    foreach($relative in $Changes.Keys){
        if($relative -notin $allowed){throw 'API 事务包含非受管理文件。'}
        $path=Join-Path $Root $relative;Assert-NoReparsePoint $path
        $before[$relative]=if(Test-Path -LiteralPath $path){[IO.File]::ReadAllBytes($path)}else{$null}
        if(Test-Path -LiteralPath $path){$probe=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$probe.Dispose()}
    }
    try{
        foreach($relative in $Changes.Keys){
            $path=Join-Path $Root $relative;$written.Add($relative)
            if($null -eq $Changes[$relative]){if(Test-Path -LiteralPath $path){[IO.File]::Delete($path)}}
            else{[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent));Write-AtomicBytes $path $Changes[$relative]}
        }
    }catch{
        $failure=$_;$restoreFailed=$false
        foreach($relative in $written){try{$path=Join-Path $Root $relative;if($null -eq $before[$relative]){if(Test-Path -LiteralPath $path){[IO.File]::Delete($path)}}else{Write-AtomicBytes $path $before[$relative]}}catch{$restoreFailed=$true}}
        if($restoreFailed){Write-Warning 'API 文件回退未全部完成，请使用配置备份恢复。'}
        throw $failure
    }
}

function Get-FullDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        throw '请选择绝对路径，例如 D:\CodexDual\API。'
    }
    if ($Path -match '[\x00-\x1f"<>|]' -or $Path.StartsWith('\\') -or $Path.Substring(2).Contains(':')) {
        throw '请使用本机磁盘路径，不支持网络路径或特殊设备路径。'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Length -le 3) { throw '不能使用磁盘根目录。' }
    return $full
}

function Test-PathOverlap([string]$First, [string]$Second) {
    $a = $First.TrimEnd('\', '/')
    $b = $Second.TrimEnd('\', '/')
    return $a.Equals($b, [StringComparison]::OrdinalIgnoreCase) -or
        $a.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $b.StartsWith($a + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePoint([string]$Path) {
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '环境路径不能包含符号链接或目录联接。' }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-EnvironmentRoot([string]$Root, [string]$OfficialHome) {
    $rootPath = Get-FullDirectory $Root
    $officialPath = Get-FullDirectory $OfficialHome
    $protected = @($officialPath, (Join-Path $env:USERPROFILE '.codex'),
        (Join-Path $env:APPDATA 'Codex'), (Join-Path $env:APPDATA 'ChatGPT'))
    if ($env:CODEX_HOME) { $protected += Get-FullDirectory $env:CODEX_HOME }
    foreach ($path in $protected) {
        if (Test-PathOverlap $rootPath $path) { throw 'API 目录与已有 Codex 环境重叠，请选择一个全新的独立目录。' }
    }
    Assert-NoReparsePoint $rootPath
    if (Test-Path -LiteralPath $rootPath) {
        if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { throw '环境路径必须是文件夹。' }
        $marker = Join-Path $rootPath '.codex-dual.json'
        if (Test-Path -LiteralPath $marker) {
            $meta = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($meta.product -ne $script:ProductId) { throw '该目录不属于本启动器。' }
        } elseif (@(Get-ChildItem -LiteralPath $rootPath -Force).Count -gt 0) {
            throw '首次设置只能使用空目录；不会接管或覆盖已有环境。'
        }
        foreach ($child in @('CodexHome','DesktopProfile','Projectless','Projects','Credentials','Backup','.codex-dual.json')) {
            Assert-NoReparsePoint (Join-Path $rootPath $child)
        }
        foreach ($file in @('CodexHome\config.toml','CodexHome\auth.json','Credentials\api-key.dpapi')) {
            Assert-NoReparsePoint (Join-Path $rootPath $file)
        }
    }
    return $rootPath
}

function ConvertTo-TomlString([string]$Value) {
    if ($Value -match '[\x00-\x1f]') { throw '输入不能包含换行或控制字符。' }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function New-ApiConfig([string]$Root, [string]$BaseUrl, [string]$Model) {
    $uri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('https','http') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'API 地址必须是 http(s) URL，不能包含用户名、密码、查询参数或片段。'
    }
    if ($uri.Scheme -eq 'http' -and -not $uri.IsLoopback) { throw '非本机 API 地址必须使用 HTTPS。' }
    if ([string]::IsNullOrWhiteSpace($Model)) { throw '请填写服务商支持的模型 ID。' }
    $modelText = ConvertTo-TomlString $Model.Trim()
    $urlText = ConvertTo-TomlString $BaseUrl.Trim().TrimEnd('/')
    $workspaceText = ConvertTo-TomlString (Join-Path $Root 'Projectless')
    return @"
# Managed by Codex Dual Launcher. Backed up before each update.
forced_login_method = "api"
cli_auth_credentials_store = "file"
model_provider = "dual-api"
model = $modelText

[model_providers.dual-api]
name = "API Environment"
base_url = $urlText
wire_api = "responses"
requires_openai_auth = false
env_key = "CODEX_DUAL_API_KEY"

[desktop]
projectlessWorkspaceRoot = $workspaceText
"@
}

function Write-AtomicText([string]$Path, [string]$Text) {
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
    }
}

function Save-ApiEnvironment {
    param([string]$Root, [string]$OfficialHome, [string]$BaseUrl, [string]$Model, [Security.SecureString]$Key)
    $rootPath = Assert-EnvironmentRoot $Root $OfficialHome
    if((Get-ApiManagementMode $rootPath) -ne 'builtin'){throw 'API 配置由 CCS 管理，请在 CCS 中修改；需要返回内置管理时请使用控制面板的恢复入口。'}
    $configText = New-ApiConfig $rootPath $BaseUrl $Model
    $configPath = Join-Path $rootPath 'CodexHome\config.toml'
    if(Test-Path -LiteralPath $configPath){$configText=Merge-ApiConfig ([IO.File]::ReadAllText($configPath)) $rootPath $BaseUrl $Model}
    $keyPath = Join-Path $rootPath 'Credentials\api-key.dpapi'
    $authPath = Join-Path $rootPath 'CodexHome\auth.json'
    if (Test-Path -LiteralPath $authPath) {
        $existingAuth = Read-ApiAuth $authPath
        if ($existingAuth.auth_mode -ne 'apikey' -or $existingAuth.OPENAI_API_KEY -ne 'CODEX_DUAL_ENV_KEY' -or
            @($existingAuth.PSObject.Properties.Name | Where-Object { $_ -notin @('auth_mode','OPENAI_API_KEY') }).Count -gt 0) {
            throw '此 API 目录已有其他登录凭据，工具不会覆盖。请另选空目录。'
        }
    }
    if (($null -eq $Key -or $Key.Length -eq 0) -and -not (Test-Path -LiteralPath $keyPath)) { throw '首次设置需要 API Key。' }
    $encrypted = $null
    if ($null -ne $Key -and $Key.Length -gt 0) { $encrypted = ConvertFrom-SecureString -SecureString $Key }
    foreach ($directory in @('', 'CodexHome','DesktopProfile','Projectless','Projects','Credentials','Backup')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $rootPath $directory))
    }
    $marker = Join-Path $rootPath '.codex-dual.json'
    if (-not (Test-Path -LiteralPath $marker)) { Write-AtomicText $marker (@{product=$script:ProductId} | ConvertTo-Json) }
    $configPath = Join-Path $rootPath 'CodexHome\config.toml'
    if (Test-Path -LiteralPath $configPath) {
        $backupPath = Join-Path $rootPath ('Backup\config-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N') + '.toml')
        [IO.File]::Copy($configPath, $backupPath, $false)
    }
    $changes=@{'CodexHome\config.toml'=[Text.Encoding]::UTF8.GetBytes($configText)}
    if ($encrypted) { $changes['Credentials\api-key.dpapi']=[Text.Encoding]::UTF8.GetBytes($encrypted) }
    # Non-secret mode marker. Provider authentication uses the DPAPI key via env_key.
    if (-not (Test-Path -LiteralPath $authPath)) {
        $changes['CodexHome\auth.json']=[Text.Encoding]::UTF8.GetBytes('{"auth_mode":"apikey","OPENAI_API_KEY":"CODEX_DUAL_ENV_KEY"}')
    }
    $changes['.codex-dual.json']=[Text.Encoding]::UTF8.GetBytes((@{product=$script:ProductId;managementMode='builtin';baseUrl=$BaseUrl.Trim().TrimEnd('/');model=$Model.Trim()}|ConvertTo-Json))
    Write-ApiTransaction $rootPath $changes
    return $rootPath
}

function Find-CodexExecutable([string]$ExplicitPath) {
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if (Test-Path -LiteralPath $ExplicitPath -PathType Container) {
            foreach ($relative in @('app\ChatGPT.exe','app\Codex.exe','ChatGPT.exe','Codex.exe')) {
                $candidate = Join-Path $ExplicitPath $relative
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
            }
            throw '指定安装目录内未找到桌面程序。'
        }
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) -or [IO.Path]::GetExtension($ExplicitPath) -ne '.exe') {
            throw '指定的桌面程序不存在，请选择 Codex Desktop 的 ChatGPT.exe 或 Codex.exe。'
        }
        return [IO.Path]::GetFullPath($ExplicitPath)
    }
    $packages = @(Get-AppxPackage -Name '*Codex*' -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
    foreach ($package in $packages) {
        foreach ($relative in @('app\ChatGPT.exe','app\Codex.exe')) {
            $candidate = Join-Path $package.InstallLocation $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    throw '未找到 Microsoft Store 版 Codex Desktop。请安装应用，或手动选择桌面程序（不要选择命令行 codex.exe）。'
}

function New-CodexStartInfo {
    param([string]$Executable, [string]$OfficialHome, [string]$ApiRoot, [switch]$Api)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.UseShellExecute = $false
    # Remove inherited Codex session/routing state, including when launched from an API task.
    foreach ($name in @($info.EnvironmentVariables.Keys)) {
        if ($name -match '^(CODEX_|ELECTRON_|OPENAI_|CHATGPT_)' -or $name -in @('CUSTOM_API_KEY','NODE_OPTIONS')) {
            $info.EnvironmentVariables.Remove($name)
        }
    }
    if ($Api) {
        $rootPath = Assert-EnvironmentRoot $ApiRoot $OfficialHome
        if (-not (Test-Path -LiteralPath (Join-Path $rootPath '.codex-dual.json'))) { throw '请先保存 API 环境。' }
        $ccs=(Get-ApiManagementMode $rootPath) -eq 'ccs'
        $requiredFiles=@('CodexHome\config.toml','CodexHome\auth.json')
        if(-not $ccs){$requiredFiles+=@('Credentials\api-key.dpapi')}
        foreach ($required in $requiredFiles) {
            if (-not (Test-Path -LiteralPath (Join-Path $rootPath $required) -PathType Leaf)) { throw 'API 环境不完整，请重新保存配置。' }
        }
        $authState = Read-ApiAuth (Join-Path $rootPath 'CodexHome\auth.json')
        $configState = Get-Content -LiteralPath (Join-Path $rootPath 'CodexHome\config.toml') -Raw -Encoding UTF8
        $document=New-Object CodexDual.TomlConfig($configState)
        $authMode=if($authState.PSObject.Properties['auth_mode']){[string]$authState.auth_mode}else{''}
        $authKey=if($authState.PSObject.Properties['OPENAI_API_KEY']){[string]$authState.OPENAI_API_KEY}else{''}
        if (($authMode -and $authMode -ne 'apikey') -or -not $authKey -or
            $document.GetString('forced_login_method') -ne 'api' -or
            $document.GetString('cli_auth_credentials_store') -ne 'file') {
            throw 'API 登录模式设置缺失或被修改，已停止启动。请检查配置或使用新的空目录重新设置。'
        }
        if($ccs){
            $meta=Get-Content -LiteralPath (Join-Path $rootPath '.codex-dual.json') -Raw -Encoding UTF8|ConvertFrom-Json
            $settingsPath=Get-FullDirectory $meta.ccsSettingsPath;Assert-NoReparsePoint $settingsPath
            $settings=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8|ConvertFrom-Json
            if(-not $settings.PSObject.Properties['codexConfigDir'] -or -not (Get-FullDirectory $settings.codexConfigDir).Equals((Join-Path $rootPath 'CodexHome'),[StringComparison]::OrdinalIgnoreCase)){throw 'CCS 的 Codex 目录已变化，请检查接入设置。'}
            if($authKey -eq 'CODEX_DUAL_ENV_KEY' -or $document.GetString('model_provider') -eq 'dual-api'){throw '请先在 CCS 中选择并应用 API 供应商，再启动此环境。'}
        }else{
        if($authMode -ne 'apikey' -or $authKey -ne 'CODEX_DUAL_ENV_KEY'){throw 'API 认证已由其他工具修改，请通过控制面板检查管理方式。'}
        $secure = Get-Content -LiteralPath (Join-Path $rootPath 'Credentials\api-key.dpapi') -Raw -Encoding UTF8 | ConvertTo-SecureString
        $pointer = [IntPtr]::Zero
        try {
            $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            $info.EnvironmentVariables['CODEX_DUAL_API_KEY'] = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        } finally {
            if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
            $secure.Dispose()
        }
        }
        $info.EnvironmentVariables['CODEX_HOME'] = Join-Path $rootPath 'CodexHome'
        $info.Arguments = '--user-data-dir="' + (Join-Path $rootPath 'DesktopProfile') + '"'
        $info.WorkingDirectory = Join-Path $rootPath 'Projects'
    } else {
        $info.EnvironmentVariables['CODEX_HOME'] = Get-FullDirectory $OfficialHome
        $info.WorkingDirectory = $env:USERPROFILE
    }
    return $info
}

function Start-CodexEnvironment {
    param([string]$Executable, [string]$OfficialHome, [string]$ApiRoot, [switch]$Api)
    $resolved = Find-CodexExecutable $Executable
    $info = New-CodexStartInfo -Executable $resolved -OfficialHome $OfficialHome -ApiRoot $ApiRoot -Api:$Api
    try {
        $process = [Diagnostics.Process]::Start($info)
        if ($null -eq $process) { throw '系统没有返回启动进程。' }
        $id = $process.Id
        $process.Dispose()
        return $id
    } finally { $info.EnvironmentVariables.Remove('CODEX_DUAL_API_KEY') }
}

function Get-EnvironmentReport([string]$Root, [string]$OfficialHome, [string]$Executable) {
    $lines = New-Object 'Collections.Generic.List[string]'
    try { $path = Find-CodexExecutable $Executable; $lines.Add('[通过] 桌面程序：' + $path) }
    catch { $lines.Add('[问题] ' + $_.Exception.Message) }
    try {
        $rootPath = Assert-EnvironmentRoot $Root $OfficialHome
        $lines.Add('[通过] API 路径与已知官方环境不重叠。')
        foreach ($required in @('.codex-dual.json','CodexHome\config.toml','Credentials\api-key.dpapi','DesktopProfile','Projectless','Projects')) {
            if (Test-Path -LiteralPath (Join-Path $rootPath $required)) { $lines.Add('[存在] ' + $required) }
            else { $lines.Add('[缺少] ' + $required + '；请先保存配置。') }
        }
        $keyPath = Join-Path $rootPath 'Credentials\api-key.dpapi'
        if (Test-Path -LiteralPath $keyPath) {
            try {
                $secret = Get-Content -LiteralPath $keyPath -Raw -Encoding UTF8 | ConvertTo-SecureString
                $secret.Dispose()
                $lines.Add('[通过] 密钥可由当前 Windows 用户解密。')
            } catch { $lines.Add('[问题] 无法解密密钥；请在当前 Windows 账户下重新填写并保存。') }
        }
        if (Test-Path -LiteralPath (Join-Path $rootPath 'CodexHome\auth.json')) {
            $authState = Read-ApiAuth (Join-Path $rootPath 'CodexHome\auth.json')
            if ($authState.auth_mode -eq 'apikey' -and $authState.OPENAI_API_KEY -eq 'CODEX_DUAL_ENV_KEY') {
                $lines.Add('[通过] API 模式标记存在；真实密钥通过子进程环境注入。')
            } else {
                $lines.Add('[需检查] API 环境的 auth.json 不是启动器的模式标记；工具不会删除或覆盖它。')
            }
        }
        $profileArgument = '--user-data-dir="' + (Join-Path $rootPath 'DesktopProfile') + '"'
        $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe' OR Name = 'Codex.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profileArgument) -and $_.CommandLine -notmatch '--type=' })
        $lines.Add('[运行] 匹配独立 profile 的主进程数量：' + $processes.Count)
    } catch { $lines.Add('[问题] ' + $_.Exception.Message) }
    $lines.Add('')
    $lines.Add('此检查不发送 API 请求，也不能证明历史或计费已隔离。')
    $lines.Add('首次使用：确认 API 窗口没有官方历史，新建任务落在 Projectless，并在服务商后台核对用量。')
    return $lines -join [Environment]::NewLine
}
