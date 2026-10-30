# C# 0.9 预览版配图

2026-10-30 从 `0.9.0-preview.4` 的真实 C# / WinForms 控件生成，界面代码对应提交 `10c06ba`。使用隔离实例配置、合成聊天标题和完成记录；没有启动完整 Codex Desktop、发送真实模型请求或读取日常聊天。图片不是设计稿。

| 文件 | 内容 |
|---|---|
| overview-dark.png | 深色工作台与两套环境入口 |
| notifications-dark.png | 通知设置与合成的最近完成记录 |
| settings-light.png | 浅色偏好设置 |
| title-tool-dark.png | 高级页中的独立标题工具，使用合成标题列表 |

在 Windows 上构建公共包后，可通过隔离验收脚本复现：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-DotNetPackage.ps1 -Package 'C:\Build\Release\package' -OutputDirectory 'C:\Build\Fresh-Image-Test'
```

输出目录必须是新的。脚本使用合成配置，顺序打开轻量测试窗口；`screenshots-dark`、`screenshots-light` 是标准尺寸配图来源，`screenshots-dark-compact` 是最小窗口验收证据。本页图片不使用最小尺寸图。

图中模型字段显示程序默认设置，不代表推荐型号或已经获得该模型权限。图中“未运行”“等待连接”和标题列表属于隔离场景；配图不构成真实模型、原生弹窗、进程操作或提问接管的端到端证据。
