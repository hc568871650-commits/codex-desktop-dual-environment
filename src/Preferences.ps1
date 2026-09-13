Set-StrictMode -Version Latest

function Get-ControllerPreferencesPath($Config) { return Join-Path $Config.stateDirectory 'preferences.local.json' }
function Read-ControllerPreferences($Config) {
    $value=@{schema=1;names=@{};panel=$null;ccsExecutable='';ccsSettingsPath='';pendingApi=$null}
    $path=Get-ControllerPreferencesPath $Config
    Assert-NoReparsePoint $path
    if(Test-Path -LiteralPath $path){
        $saved=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if($saved.schema -ne 1){throw '不支持的面板设置版本。'}
        foreach($key in @('panel','ccsExecutable','ccsSettingsPath','pendingApi')){$value[$key]=Get-ObjectValue $saved $key $value[$key]}
        $names=Get-ObjectValue $saved 'names' $null
        if($names){foreach($property in $names.PSObject.Properties){$value.names[$property.Name]=[string]$property.Value}}
    }
    return $value
}
function Save-ControllerPreferences($Config,$Preferences) {
    $path=Get-ControllerPreferencesPath $Config;Assert-NoReparsePoint $path
    [void][IO.Directory]::CreateDirectory($Config.stateDirectory)
    Write-AtomicText $path ($Preferences|ConvertTo-Json -Depth 8)
}
function Get-InstanceDisplayName($Instance,$Preferences) {
    $default=if($Instance.role -eq 'official'){'官方环境'}else{'API 环境'}
    if($Preferences.names.ContainsKey($Instance.id) -and -not [string]::IsNullOrWhiteSpace($Preferences.names[$Instance.id])){return [string]$Preferences.names[$Instance.id]}
    return $default
}
function Set-InstanceDisplayName($Config,$Instance,[string]$Name,[switch]$Reset) {
    $preferences=Read-ControllerPreferences $Config
    if($Reset){$preferences.names.Remove($Instance.id)}else{
        $name=$Name.Trim()
        if(-not $name -or $name.Length -gt 24 -or $name -match '[\x00-\x1f\x7f]'){throw '名称应为 1–24 个字符，不能包含换行或控制字符。'}
        $preferences.names[$Instance.id]=$name
    }
    Save-ControllerPreferences $Config $preferences
    return $preferences
}
function Get-VisiblePanelPoint($Saved,[int]$Width,[int]$Height,$Areas) {
    $areasList=@($Areas);if(-not $areasList.Count){throw '未找到可用屏幕。'}
    $area=$areasList[0]
    if($null -ne $Saved){
        $x=[int]$Saved.x;$y=[int]$Saved.y
        foreach($candidate in $areasList){if($x -ge $candidate.X -and $x -lt ($candidate.X+$candidate.Width) -and $y -ge $candidate.Y -and $y -lt ($candidate.Y+$candidate.Height)){$area=$candidate;break}}
    }else{$x=$area.X+[int](($area.Width-$Width)/2);$y=$area.Y+[int](($area.Height-$Height)/2)}
    return @{x=[Math]::Max($area.X,[Math]::Min($x,$area.X+[Math]::Max(0,$area.Width-$Width)));y=[Math]::Max($area.Y,[Math]::Min($y,$area.Y+[Math]::Max(0,$area.Height-$Height)))}
}
function Get-ControllerStartupName([string]$ConfigPath) {
    $hash=[Security.Cryptography.SHA256]::Create()
    try{return 'CodexDualController.'+[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-FullDirectory $ConfigPath).ToLowerInvariant()))).Replace('-','').Substring(0,16)}finally{$hash.Dispose()}
}
function Register-ControllerInstallation([string]$ToolRoot,[string]$RegistryPath='HKCU:\Software\CodexDualController\Installations') {
    $root=Get-FullDirectory $ToolRoot
    $name=Get-ControllerStartupName (Join-Path $root 'instances.local.json')
    if(-not (Test-Path -LiteralPath $RegistryPath)){[void](New-Item -Path $RegistryPath -Force)}
    [void](New-ItemProperty -LiteralPath $RegistryPath -Name $name -Value $root -PropertyType String -Force)
}
function Unregister-ControllerInstallation([string]$ToolRoot,[string]$RegistryPath='HKCU:\Software\CodexDualController\Installations') {
    $name=Get-ControllerStartupName (Join-Path $ToolRoot 'instances.local.json')
    $values=Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction SilentlyContinue
    if($values -and $values.PSObject.Properties[$name] -and (Test-SamePath ([string]$values.$name) $ToolRoot)){Remove-ItemProperty -LiteralPath $RegistryPath -Name $name}
}
function Get-ControllerStartupCommand([string]$ToolRoot,[string]$ConfigPath) {
    return '"'+(Join-Path (Get-FullDirectory $ToolRoot) 'CodexDualController.exe')+'" --config "'+(Get-FullDirectory $ConfigPath)+'"'
}
function Get-LegacyControllerStartupCommand([string]$ToolRoot,[string]$ConfigPath) {
    return '"'+(Join-Path (Get-FullDirectory $ToolRoot) 'CodexDualController.exe')+'" --background --config "'+(Get-FullDirectory $ConfigPath)+'"'
}
function Test-ControllerAutoStart([string]$ToolRoot,[string]$ConfigPath,[string]$RegistryPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') {
    $name=Get-ControllerStartupName $ConfigPath
    $values=Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction SilentlyContinue
    return $null -ne $values -and $values.PSObject.Properties[$name] -and [string]$values.$name -eq (Get-ControllerStartupCommand $ToolRoot $ConfigPath)
}
function Set-ControllerAutoStart([string]$ToolRoot,[string]$ConfigPath,[bool]$Enabled,[string]$RegistryPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') {
    $name=Get-ControllerStartupName $ConfigPath;$command=Get-ControllerStartupCommand $ToolRoot $ConfigPath
    $values=Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction SilentlyContinue
    $legacy=Get-LegacyControllerStartupCommand $ToolRoot $ConfigPath
    if($values -and $values.PSObject.Properties[$name] -and [string]$values.$name -notin @($command,$legacy)){throw '同名自启动项已被其他入口修改，保留现有项，请先检查 Windows 启动设置。'}
    if($Enabled){
        $hostPath=Join-Path $ToolRoot 'CodexDualController.exe';Assert-NoReparsePoint $hostPath
        if(-not (Test-Path -LiteralPath $hostPath -PathType Leaf)){throw '控制器 EXE 尚未生成，请先完成安装或升级。'}
        if(-not (Test-Path -LiteralPath $RegistryPath)){[void](New-Item -Path $RegistryPath -Force)}
        [void](New-ItemProperty -LiteralPath $RegistryPath -Name $name -Value $command -PropertyType String -Force)
    }elseif($values -and $values.PSObject.Properties[$name]){Remove-ItemProperty -LiteralPath $RegistryPath -Name $name}
}
function Repair-ControllerAutoStart([string]$ToolRoot,[string]$ConfigPath,[string]$RegistryPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') {
    $name=Get-ControllerStartupName $ConfigPath
    $values=Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction SilentlyContinue
    if($values -and $values.PSObject.Properties[$name] -and [string]$values.$name -eq (Get-LegacyControllerStartupCommand $ToolRoot $ConfigPath)){
        Set-ControllerAutoStart $ToolRoot $ConfigPath $true $RegistryPath
    }
    return Test-ControllerAutoStart $ToolRoot $ConfigPath $RegistryPath
}
