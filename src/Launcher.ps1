param(
    [string]$SettingsPath = (Join-Path $env:LOCALAPPDATA 'CodexDualLauncher\settings.json'),
    [switch]$SmokeTest,
    [string]$ScreenshotPath
)

$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    . (Join-Path $PSScriptRoot 'Core.ps1')
    [Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object Windows.Forms.Form
    $form.Text = 'Codex 双环境启动器'
    $form.ClientSize = New-Object Drawing.Size(960, 780)
    $form.MinimumSize = New-Object Drawing.Size(920, 810)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = [Drawing.ColorTranslator]::FromHtml('#F3F5F8')
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
    $form.AutoScaleMode = 'Dpi'

    function Add-Label($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 25) {
        $control = New-Object Windows.Forms.Label
        $control.Text = $Text
        $control.SetBounds($X, $Y, $Width, $Height)
        $Parent.Controls.Add($control)
        return $control
    }
    function Add-TextBox($Parent, [int]$X, [int]$Y, [int]$Width) {
        $control = New-Object Windows.Forms.TextBox
        $control.SetBounds($X, $Y, $Width, 29)
        $Parent.Controls.Add($control)
        return $control
    }
    function Add-Button($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [scriptblock]$Action) {
        $control = New-Object Windows.Forms.Button
        $control.Text = $Text
        $control.SetBounds($X, $Y, $Width, 36)
        $control.FlatStyle = 'Flat'
        $control.BackColor = [Drawing.Color]::White
        $control.Cursor = [Windows.Forms.Cursors]::Hand
        $control.Add_Click($Action)
        $Parent.Controls.Add($control)
        return $control
    }
    function Invoke-UiAction([scriptblock]$Action) {
        $form.UseWaitCursor = $true
        try { & $Action }
        catch {
            $status.Text = '操作未完成，请按提示修正。'
            [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '需要处理', 'OK', 'Warning')
        } finally { $form.UseWaitCursor = $false }
    }
    function Select-Folder($Target) {
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        $dialog.Description = '请选择文件夹；API 环境首次设置必须使用空目录。'
        if (Test-Path -LiteralPath $Target.Text -PathType Container) { $dialog.SelectedPath = $Target.Text }
        try { if ($dialog.ShowDialog($form) -eq 'OK') { $Target.Text = $dialog.SelectedPath } }
        finally { $dialog.Dispose() }
    }

    $title = Add-Label $form '两个入口，各自工作。' 28 22 800 40
    $title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 21, [Drawing.FontStyle]::Bold)
    $subtitle = Add-Label $form '为 Codex Desktop 配置独立的 API 环境，保留原有官方环境。' 30 68 890
    $subtitle.ForeColor = [Drawing.ColorTranslator]::FromHtml('#566274')

    $panel = New-Object Windows.Forms.Panel
    $panel.SetBounds(28, 112, 904, 412)
    $panel.BackColor = [Drawing.Color]::White
    $panel.Anchor = 'Top,Left,Right'
    $form.Controls.Add($panel)
    $section = Add-Label $panel '01  配置环境' 20 14 800 30
    $section.Font = New-Object Drawing.Font('Microsoft YaHei UI', 12, [Drawing.FontStyle]::Bold)

    [void](Add-Label $panel 'API 存储目录' 20 60 145)
    $rootBox = Add-TextBox $panel 168 56 606
    $rootBox.Text = Join-Path $env:LOCALAPPDATA 'CodexDual\API'
    [void](Add-Button $panel '浏览…' 786 53 96 { Select-Folder $rootBox })
    [void](Add-Label $panel '首次选择空目录；配置、桌面数据和任务将保存在这里。' 168 88 705)

    [void](Add-Label $panel 'API 地址' 20 129 145)
    $urlBox = Add-TextBox $panel 168 125 714
    $urlBox.Text = 'https://api.openai.com/v1'
    [void](Add-Label $panel '模型 ID' 20 169 145)
    $modelBox = Add-TextBox $panel 168 165 714
    [void](Add-Label $panel 'API Key' 20 209 145)
    $keyBox = Add-TextBox $panel 168 205 714
    $keyBox.UseSystemPasswordChar = $true
    [void](Add-Label $panel '使用 Windows 加密保存；更新配置时留空可保留已有密钥。' 168 239 714)

    [void](Add-Label $panel '桌面程序' 20 282 145)
    $exeBox = Add-TextBox $panel 168 278 606
    [void](Add-Button $panel '选择…' 786 275 96 {
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Title = '选择 Codex Desktop 桌面程序，不要选择 CLI'
        $dialog.Filter = '桌面程序 (*.exe)|*.exe'
        try { if ($dialog.ShowDialog($form) -eq 'OK') { $exeBox.Text = $dialog.FileName } }
        finally { $dialog.Dispose() }
    })
    [void](Add-Label $panel '留空时，每次启动自动检测 Microsoft Store 安装位置。' 168 312 714)
    [void](Add-Label $panel '官方配置目录' 20 357 145)
    $officialBox = Add-TextBox $panel 168 353 606
    $officialBox.Text = Join-Path $env:USERPROFILE '.codex'
    [void](Add-Button $panel '浏览…' 786 350 96 { Select-Folder $officialBox })
    [void](Add-Label $panel '通常保持默认；如果官方环境原本使用自定义 CODEX_HOME，请选原目录。' 168 384 720)

    function Get-UiSettings {
        return [ordered]@{root=$rootBox.Text.Trim(); baseUrl=$urlBox.Text.Trim(); model=$modelBox.Text.Trim();
            executable=$exeBox.Text.Trim(); officialHome=$officialBox.Text.Trim()}
    }
    $script:savedSignature = ''
    if (Test-Path -LiteralPath $SettingsPath) {
        try {
            $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $rootBox.Text = $settings.root
            $urlBox.Text = $settings.baseUrl
            $modelBox.Text = $settings.model
            $exeBox.Text = $settings.executable
            $officialBox.Text = $settings.officialHome
            $script:savedSignature = Get-UiSettings | ConvertTo-Json -Compress
        } catch {
            [void][Windows.Forms.MessageBox]::Show('无法读取启动器设置，已显示默认值。原 API 环境未被修改。', '设置读取失败')
        }
    }

    $saveButton = Add-Button $form '保存 API 配置' 28 542 184 {
        Invoke-UiAction {
            $values = Get-UiSettings
            [void](Assert-EnvironmentRoot $values.root $values.officialHome)
            [void](New-ApiConfig $values.root $values.baseUrl $values.model)
            if (Test-Path -LiteralPath (Join-Path $values.root 'CodexHome\config.toml')) {
                $answer = [Windows.Forms.MessageBox]::Show($form,
                    '将备份并重新生成此 API 环境的 config.toml。手动添加的 MCP、服务商及其他配置不会自动合并。请先关闭 API 窗口，保存后重新启动。是否继续？',
                    '更新 API 配置', 'YesNo', 'Warning')
                if ($answer -ne 'Yes') { return }
            }
            $secure = $null
            try {
                if ($keyBox.Text.Length -gt 0) { $secure = ConvertTo-SecureString $keyBox.Text -AsPlainText -Force }
                [void](Save-ApiEnvironment -Root $values.root -OfficialHome $values.officialHome -BaseUrl $values.baseUrl -Model $values.model -Key $secure)
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($SettingsPath))
                Write-AtomicText $SettingsPath ($values | ConvertTo-Json)
                $keyBox.Clear()
                $script:savedSignature = $values | ConvertTo-Json -Compress
                $status.Text = '已保存。点击“启动 API 环境”，然后完成首次隔离验证。'
                $reportBox.Text = Get-EnvironmentReport $values.root $values.officialHome $values.executable
            } finally { if ($null -ne $secure) { $secure.Dispose() } }
        }
    }
    $saveButton.BackColor = [Drawing.ColorTranslator]::FromHtml('#176B51')
    $saveButton.ForeColor = [Drawing.Color]::White
    $officialButton = Add-Button $form '启动官方环境' 226 542 180 {
        Invoke-UiAction {
            $values = Get-UiSettings
            $processId = Start-CodexEnvironment -Executable $values.executable -OfficialHome $values.officialHome
            $status.Text = '已发出官方环境启动请求（进程 ' + $processId + '），请检查应用窗口。'
        }
    }
    $apiButton = Add-Button $form '启动 API 环境' 420 542 180 {
        Invoke-UiAction {
            $values = Get-UiSettings
            if (($values | ConvertTo-Json -Compress) -ne $script:savedSignature -or $keyBox.Text.Length -gt 0) {
                throw '配置有未保存的改动，请先保存 API 配置。'
            }
            $processId = Start-CodexEnvironment -Executable $values.executable -OfficialHome $values.officialHome -ApiRoot $values.root -Api
            $status.Text = '已发出 API 环境启动请求（进程 ' + $processId + '）。是否可用请在窗口中验证。'
        }
    }
    $checkButton = Add-Button $form '检查环境' 614 542 154 {
        Invoke-UiAction {
            $values = Get-UiSettings
            $reportBox.Text = Get-EnvironmentReport $values.root $values.officialHome $values.executable
            $status.Text = '检查完成，结果见下方。'
        }
    }
    [void](Add-Button $form '打开目录' 782 542 150 {
        Invoke-UiAction {
            $path = Get-FullDirectory $rootBox.Text.Trim()
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw '目录尚不存在，请先保存配置。' }
            Start-Process -FilePath explorer.exe -ArgumentList ('"' + $path + '"')
        }
    })
    $status = Add-Label $form '填写 API 地址、模型和密钥，保存后即可启动。' 30 594 900 26
    $status.ForeColor = [Drawing.ColorTranslator]::FromHtml('#176B51')
    $reportBox = New-Object Windows.Forms.TextBox
    $reportBox.SetBounds(28, 630, 904, 122)
    $reportBox.Multiline = $true
    $reportBox.ReadOnly = $true
    $reportBox.ScrollBars = 'Vertical'
    $reportBox.BackColor = [Drawing.Color]::White
    $reportBox.BorderStyle = 'FixedSingle'
    $reportBox.Anchor = 'Top,Bottom,Left,Right'
    $reportBox.Text = '环境检查会显示安装位置、目录与密钥状态。' + [Environment]::NewLine +
        '首次使用请确认：API 窗口没有官方历史；新任务写入独立目录；请求使用 API 额度。' + [Environment]::NewLine +
        '同一个真实项目文件夹仍是共享文件，不要让两个窗口同时修改同一份工作文件。'
    $form.Controls.Add($reportBox)

    if ($SmokeTest) {
        if (-not $ScreenshotPath) { throw 'SmokeTest 需要 ScreenshotPath。' }
        # Exercise the actual check button without launching Codex or saving a real profile.
        $form.Show()
        $checkButton.PerformClick()
        [Windows.Forms.Application]::DoEvents()
        if ($status.Text -ne '检查完成，结果见下方。' -or -not $reportBox.Text.Contains('不发送 API 请求')) { throw '界面检查按钮测试失败。' }
        $bitmap = New-Object Drawing.Bitmap($form.Width, $form.Height)
        try {
            $form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
            $bitmap.Save($ScreenshotPath, [Drawing.Imaging.ImageFormat]::Png)
        } finally { $bitmap.Dispose(); $form.Close(); $form.Dispose() }
        Write-Output 'GUI smoke test passed.'
    } else {
        [void]$form.ShowDialog()
        $form.Dispose()
    }
} catch {
    if ($SmokeTest) { throw }
    try { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, '启动器无法运行', 'OK', 'Error') }
    catch { Write-Error '启动器无法运行，请通过 PowerShell 执行 src\Launcher.ps1 查看错误。' }
    exit 1
}
