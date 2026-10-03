# API 双向提问桥接：隔离实验

2026-10-03 新增同步/异步提问接管及可切换窗口行为，仍在隔离实验交付。接管模式用 `New-TakeoverTrial.ps1` 创建，普通 `New-BridgeTrial.ps1` 默认保持镜像兼容。参见 [本轮实现与验证](../../docs/CHECKPOINT-QUESTION-TAKEOVER-20261003.md) 和 [异步接管协议](../../docs/ASYNC-TAKEOVER-PROTOCOL-20261003.md)。下列原型说明描述默认镜像路径，不代表接管模式会继续同时显示两套问题。

本目录是可回退的接入原型，不随标准安装 ZIP 交付。2026-10-03 的本机维护流程已完成日常 API 绑定及局部验证；这不是公共安装入口，也不代表其他机器已经接入。最新范围见 [0.8.8 发布说明草案](../../docs/RELEASE-0.8.8.md)。不要把协议模拟、真实 CLI 握手或桌面启动成功当作完整问答与全通知接管验收。

## 已实现的范围

- CLI stdio 代理保留原生消息，镜像 `item/tool/requestUserInput` 到当前 Windows 用户限定的命名管道。
- 独立提问窗口显示多题、选项和说明、自由输入及敏感输入；只有用户点击提交才回传。窗口关闭不替用户回答或取消。
- 以实例、连接、请求 ID、请求 token、线程和轮次绑定答案，避免过期请求与两处回答重复提交。
- 原生窗口可以照常处理；未知交互（审批、选项选择器等）透明经过代理，不假装已经接管。
- 默认旧镜像模式保留单 owner 兼容；启用 multiConnection 的接管配置为各 app-server 建立独立管道与身份记录，控制器汇总并精确路由回答。CLI 子进程不递归调用代理。
- 不记录问题、回答、密钥或完整协议流。测试 fixture 使用明确的虚拟内容。

## 创建与启动

使用 Windows PowerShell 5.1：

```powershell
.\New-BridgeTrial.ps1 -Destination 'E:\Trials\NewBridgeTrial' `
  -RealCli 'C:\path\to\codex.exe' -DesktopExecutable 'C:\path\to\ChatGPT.exe'
```

目标目录必须不存在。脚本创建独立的 CodexHome、DesktopProfile 和 Projects，不复制日常认证和聊天历史；目录仅当前用户可访问。EXE 路径及 SHA-256 记录在 trial.json，启用时核验，变更后应重建新实验。

生成的目录默认停用桥接，包含以下入口：

| 入口 | 作用 |
|---|---|
| `Enable-BridgeTrial.cmd` | 仅为下次隔离启动启用桥接；已停用的运行中代理不会被重新启用 |
| `Start-BridgeTrial.cmd` | 启动绑定的独立测试桌面；是否实际经过代理还须检查握手 |
| `Open-Questions.cmd` | 打开提问窗口；连接不可用时提示返回原窗口 |
| `Rollback-ApiBridge.cmd` | 一键停用桥接，不终止任务、不删除数据 |
| `Start-WithoutBridge.cmd` | 明确绕过桥接，启动同一个隔离桌面 |

## 回退的准确含义

`Rollback-ApiBridge.ps1` 先校验实验标记与目录绑定，再原子写入 `DISABLED`。正在运行的代理在下一次处理消息时停止接受外部回答，清除镜像待答列表，保持原生透传。由于原问题始终转发给原生窗口，回退不需要制造默认答案或取消请求。

回退后代理进程仍可能位于现有连接中；要彻底从运行链路移除，关闭**隔离测试窗口**后使用 `Start-WithoutBridge.cmd`。脚本不会按进程名称杀 Codex，也不会自动关闭日常 API 或官方实例。重复回退安全，不要求代理仍能启动。它写入 `rollback-result.json` 记录范围，不删除聊天、profile、配置或可执行文件。

本轮没有修改日常 API 启动器，因此这里没有需要恢复的日常配置备份。未来正式接入时，必须另外备份实际修改的启动入口并验证恢复；不能把本实验回退脚本说成任何历史改动的通用恢复器。

## 验证

- `tests/Test-BridgeTransport.ps1`：模拟服务协议、竞答、错绑定、ID 复用、请求失效、回退、并行实例、EOF 和原生透传。
- `tests/Test-TrialRecovery.ps1`：默认停用、独立环境、启用与绕过、重复回退、数据保留、目录篡改拒绝和防覆盖。
- `tests/Test-QuestionClient.ps1`：实际 WinForms 控件选择/输入经过管道到模拟服务、Unicode、敏感输入隐藏、问题清除和回退后原生可用。
- `tests/Test-RealCli.ps1 -TrialDirectory <目录>`：使用已绑定的真实 CLI 做 initialize/config/read 和回退后再读取，不发送模型任务或使用真实凭据。
- `tests/Test-DesktopTrial.ps1 -TrialDirectory <目录>`：校验真实桌面的代理归属和管道，再执行回退并验证下一次原生绕过启动；只清理此次身份核验通过的隔离进程树。

真实桌面加载与绕过启动已在本机 26.924.2738.0 的独立 profile 验证。仍须验证：真实生成提问及原窗口同步、精确返回任务、异步扩展交互和逐类原生通知抑制。当前原型不关闭任何原生通知，不宣称完全接管。阶段证据见仓库 `docs/CHECKPOINT-NOTIFICATIONS-NEXT.md`。
