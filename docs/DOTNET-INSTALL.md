# C# 预览版安装、升级与回退

适用版本：**0.9.0-preview.4**，Windows x64。公开 ZIP 包含 .NET 10 Desktop 运行时，无需安装 SDK 或额外运行时；需要 Windows PowerShell 5.1 和已安装的 Codex Desktop。ARM64、32 位和网络目录未支持。

## 首次安装

1. 从本版本 Release 下载 `CodexDualController-0.9.0-preview.4-win-x64.zip` 与 `SHA256SUMS.txt`，用 `Get-FileHash <ZIP> -Algorithm SHA256` 核对摘要。
2. 解压到独立下载目录，双击 `Install.cmd`。输入一个新的空工具目录；直接回车使用 `%LOCALAPPDATA%\CodexDualController`。
3. 填写现有官方 `CODEX_HOME`、API 地址、模型 ID 和密钥。密钥隐藏输入并用当前 Windows 用户的 DPAPI 加密。新 API 数据默认位于 `%LOCALAPPDATA%\CodexDualData\API`，不会复制官方认证或历史。
4. 安装后可打开控制器，或使用生成的三个快捷方式。安装过程本身不启动、停止 Codex。工具目录与解压目录、官方数据和 API 数据必须分开。

已有官方 `config.toml` 需要可解析的 `[desktop] projectlessWorkspaceRoot`。遇到缺失或复杂写法，安装器会停止并保留原配置。自定义路径示例：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File scripts\Bootstrap-DotNet.ps1 -TargetDirectory 'C:\CodexDual\Tool' -DataDirectory 'C:\CodexDual\Data' -OfficialHome 'C:\MyCodexHome' -Executable 'C:\InstalledCodex\Codex.exe'
```

示例路径需替换为真实路径。不要在命令行中传入明文密钥。保留源 ZIP 和下载目录，便于工具卸载或回退。

## 从 0.8.9 或 C# 预览版升级

1. 从托盘退出目标控制器，两套 Codex 可以继续运行。
2. 将新 ZIP 解压到独立目录。运行 `Upgrade.cmd`，输入原工具安装的**实际目录**，不要选择目录联接或 Codex 数据目录。
3. 安装器核对旧文件与包清单，拒绝覆盖修改过或不属于旧清单的文件；保留实例配置、凭据、通知状态、聊天和用户设置。
4. 默认在工具目录旁生成独立备份，完成后打印 `receipt.json` 路径。保存这份收据及完整备份目录。旧控制面板快捷方式继续指向同一 EXE；旧官方/API 快捷方式仍可沿用。

同一个 ZIP 支持首次安装和升级，没有另一个容易混淆的升级附件。若旧预览包未带有某些源文件的清单、或者手动修改过工具，请先比较并自行保存这些修改；安装器不会自动覆盖。

```powershell
# 只预检；不修改安装
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Bootstrap-DotNet.ps1 -TargetDirectory 'C:\CodexDual\Tool' -CheckOnly -NonInteractive
# 使用指定的新备份目录升级，不自动启动控制器
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Bootstrap-DotNet.ps1 -TargetDirectory 'C:\CodexDual\Tool' -BackupDirectory 'C:\CodexDual\Backup-preview4' -NoLaunch -NonInteractive
```

## 标题建议：可选实验功能

默认关闭。已有明确保存的设置在升级时保留。启用前在高级设置中核对模型和凭据；模型费用由实际渠道决定。

```powershell
# 在已安装工具目录执行，模型 ID 替换为渠道支持的值
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Set-DotNetTitle.ps1 -Mode enable -Model 'your-model-id'
# 停用
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Set-DotNetTitle.ps1 -Mode disable
```

保存后重启控制器。托管 API 环境在下次从控制器打开时添加回环调试参数；需要等 API 任务完成后完整退出并重新打开 Desktop。

外部启动器不会被公共升级入口自动改写。外部环境维护者需在**实际 API Desktop 启动位置**保留原有 home/profile/凭据设置，并额外传入 `--remote-debugging-port=0 --remote-debugging-address=127.0.0.1`；不要添加到官方环境，不要暴露到局域网。停用时关闭标题设置，并删除这两个参数后重新打开 API Desktop。外部凭据通过高级凭据设置登记其 DPAPI 文件。

只有已使用 `CODEX NATIVE TITLE v1` 标记段的旧启动器才适用 `Install-DotNetLocal.ps1 -ApiLauncher` 的维护迁移接口；普通用户不应直接套用。修改外部启动器前另存原文件，回退时恢复自己的启动段。

标题建议的连接、离线兼容探针与原生弹窗完整交互是不同的验收层级。生成、采用、手动编辑、原生保存和侧栏刷新尚未完成所有上游版本的真实验收。提问桥接也保持独立实验范围，公共包不安装代理或接管原生问题。

## 回退与卸载

退出控制器后，从保留的下载目录运行：

```powershell
# 先预检
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Rollback-DotNetLocal.ps1 -Receipt 'C:\CodexDual\Backup-preview4\receipt.json'
# 核对目标后执行
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Rollback-DotNetLocal.ps1 -Receipt 'C:\CodexDual\Backup-preview4\receipt.json' -Apply
```

回退恢复这次升级前的工具和安装清单；遇到安装后被修改的工具会停止，避免覆盖。回退不重置 Codex 版本，也不删除聊天。首次安装没有旧版本回退收据，可退出控制器后运行已安装目录的 `Uninstall.cmd`，按清单删除未修改工具文件和原位置快捷方式；保留配置、密钥、状态、聊天、备份与修改过的文件。卸载不会恢复手动修改的外部启动器，需由维护者恢复其备份。

## 验证边界

发布验收使用隔离配置、合成凭据和单个轻量 WinForms 窗口，不调用真实模型，不启动完整 Codex Desktop。自包含包在清空运行时环境变量的子进程中启动验证；这不等于已经覆盖所有干净 Windows 系统。自然通知、跨窗口行为、长期稳定性与实验标题/提问全流程仍需实际使用反馈。
