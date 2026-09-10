# 使用指南

## 首次配置

完整解压程序后双击 `Start.cmd`。这是原生 Windows 窗口，不是网页；需要保留 `src` 文件夹。没有管理员权限也可以使用。

1. **API 存储目录**：默认 `%LOCALAPPDATA%\CodexDual\API`，可改为例如 `D:\CodexDual\API`。首次必须为空目录或尚不存在的目录。不要选现有官方或 API 环境。
2. **API 地址**：填写服务商提供的 Responses API 基础地址，例如 `https://api.openai.com/v1`，不要填写完整 `/responses` 端点。仅本机服务允许 HTTP，其他地址要求 HTTPS。
3. **模型 ID**：填写服务商实际支持的模型名称。工具不会猜测模型，也不会查询模型列表。
4. **API Key**：首次必填；之后留空保留旧密钥。输入框隐藏内容，保存成功后清空。
5. **桌面程序**：通常留空。自动检测 Store 安装；非 Store 安装可手动选 Codex Desktop 目录中的 `ChatGPT.exe` 或 `Codex.exe`。不要选择 `resources\codex.exe` 等命令行程序。
6. **官方配置目录**：默认 `%USERPROFILE%\.codex`。如果以前为官方环境自定义了 `CODEX_HOME`，请填原目录。工具不导入、不重写其中的文件。

点击“保存 API 配置”后，再点击“启动 API 环境”。“启动官方环境”不要求先配置 API Key。启动提示只表示 Windows 已接收启动请求，不保证应用已经显示、API 可用或认证成功。

## 保存了哪些文件

```text
<API 存储目录>
├─ .codex-dual.json        # 工具标记、地址和模型，不含密钥
├─ CodexHome/config.toml  # API provider、API 登录限制和独立任务目录
├─ CodexHome/auth.json    # 仅 API 模式占位标记，不含真实服务商密钥
├─ Credentials/api-key.dpapi
├─ DesktopProfile/
├─ Projectless/
├─ Projects/
└─ Backup/                # 更新前的 config.toml
```

启动器另在 `%LOCALAPPDATA%\CodexDualLauncher\settings.json` 保存表单字段和路径，不含密钥。上述运行数据不应提交到 GitHub。密钥文件受当前 Windows 用户的 DPAPI 保护，复制到另一台电脑或另一账户可能无法解密；应重新输入密钥。

启动器创建的 auth.json 使用固定的 CODEX_DUAL_ENV_KEY 占位值，仅用于进入 API 模式。真正认证由配置中的 env_key 完成。发现目录中已有其他认证时拒绝覆盖；启动时发现模式约束被改变则停止。

启动器不设置系统或用户级 `CODEX_HOME`、API Key。API Key 通过 `ProcessStartInfo` 的子进程环境传递；不会短暂写进父进程环境。官方子进程会移除继承的 Codex 会话变量、已知 API 路由变量和 Electron/Node 启动变量，再设置用户选择的官方 `CODEX_HOME`。

## 更新配置与恢复

改地址、模型或密钥之前，先在 API 窗口完成任务并正常关闭窗口。保存时工具会确认更新，并将原 `CodexHome/config.toml` 完整备份到 `Backup`。

**保存会重新生成整个 API config.toml**，不会自动合并手写的 MCP、其他 provider、插件等设置。已交给 CC Switch 管理的配置不适合再用此表单保存；可以保留启动入口，使用 CC Switch 管理配置，并自行核对密钥来源。当前启动器始终读取自身的 DPAPI 密钥，因此 CC Switch 更换密钥不会自动更新启动器密钥。

恢复配置：关闭 API 窗口，保留当前配置副本，将选定备份复制回 `CodexHome/config.toml`，重新启动 API 环境。备份不包含旧密钥；需要恢复密钥时重新填写。更换到全新 API 存储目录不会迁移历史或密钥。

首次初始化中途失败时，可能留下带工具标记的部分目录。修复磁盘空间或权限后，在相同路径重新保存即可。工具不提供自动删除或强制关闭 Codex 的功能。

## 首次隔离验收

“检查环境”不发送请求。它检查程序位置、路径关系、所需文件、DPAPI 解密和独立 profile 的主进程参数；不能证明服务商兼容性、认证身份或计费来源，也不验证手动修改过的 TOML 是否仍正确。

第一次使用或 Codex Desktop 更新后，请手动验证：

- 官方窗口仍显示原有账号、项目和历史。
- API 窗口没有复制过来的官方历史；不要在 API 窗口登录官方账号。
- API 窗口中新建的无项目任务实际写入指定 `Projectless` 目录。
- API 窗口中新建的任务或项目条目没有出现在官方窗口。
- 各发送一个小请求，并分别在订阅和 API 服务商侧核对用量。
- 关闭一个窗口不会关闭另一个。

如果第二次启动只激活原窗口，或者两边出现相同历史，停止在该环境中工作，检查 `--user-data-dir` 参数是否生效。此时不能声称双开已隔离。独立 profile 和 `desktop.projectlessWorkspaceRoot` 需要由实际桌面版本支持；本工具不能替代上述验收。

两边主动打开同一个真实项目目录时，底层文件仍然共享。若要并行修改代码，请使用独立工作副本或 Git worktree。

## 常见问题

**双击没有窗口：** 完整解压后重试。如果公司策略阻止脚本，请遵循组织政策。可在仓库目录运行下列命令查看错误，命令只改变该 PowerShell 进程的执行策略：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File src\Launcher.ps1
```

**找不到桌面程序：** 安装 Codex Desktop，或用“选择…”指定桌面可执行文件。应用更新后手动路径可能失效，Store 版建议留空自动检测。

**提示目录重叠或非空：** 工具不接管现有目录。选择全新的文件夹。为了避免修改正在运行的环境，继承的 `CODEX_HOME` 也被列入保护范围。

**密钥无法解密：** 在实际使用此工具的 Windows 账户下重新输入并保存密钥。不要上传密钥文件排查。

**API 返回 401/404 或模型错误：** 在服务商文档中核对基础地址、API Key、模型及 Responses API 支持情况。启动器不会做协议转换或自动降级。

**点击启动后没有新窗口：** 检查是否已经有同 profile 的进程，或桌面版本是否接受独立 profile 参数。先正常关闭 API 窗口再试，不要强制结束所有 Codex 进程。

**如何停用：** 正常关闭 API 窗口即可。程序文件、启动器设置和 API 数据独立存放。需要删除时先备份有用任务；工具不会删除官方环境或安装程序。

## 测试与打包

`tests/Test-Core.ps1` 在仓库 `test-results` 中创建随机目录，使用假密钥验证路径防护、TOML 转义、DPAPI、备份、中文与空格路径以及真实子进程环境。测试数据不会自动删除，以便检查失败现场；整个目录被 Git 忽略。

图形冒烟测试可在 Windows 交互会话运行。它构建实际窗体、点击“检查环境”并渲染截图，不启动 Codex，不保存 API 环境：

```powershell
New-Item -ItemType Directory -Force test-results | Out-Null
$resultDir = (Resolve-Path test-results).Path
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File src\Launcher.ps1 `
  -SmokeTest -SettingsPath "$resultDir\gui-settings.json" -ScreenshotPath "$resultDir\launcher.png"
```

`scripts/Build-Release.ps1` 只打包入口、源码和文档。它不会打包 `test-results`、开发机配置、API 环境、密钥或 Codex 本体。同一版本的现有 ZIP 不会被覆盖。
