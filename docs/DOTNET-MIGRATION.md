# C# 控制器迁移

后续的 `0.9.0-preview.2` 界面调整与验收见 [界面更新记录](UI-REFRESH-0.9.md)。下文保留首次迁移的验证边界。

用户授权：在独立目录迁移到 C# / .NET 10，优先标题推荐和通知监测；通过功能与性能验收后替换日常控制器，保留回退。

源基线：0.8.9 / 98ff78d。开发工作树 `codex-dual-controller-dotnet`，分支 `codex/dotnet-migration`。现有安装及外部 API 启动器作为基线，未验收前不覆盖。

## 必须保留

- 官方 / API 的 home、profile、凭据及进程身份隔离，PID 创建时间和路径校验。
- 不重放历史完成事件，严格 UTF-8、半行、文件截断/替换、去重、子代理排除、API 前台静默。
- 原生标题建议不能覆盖手动输入，采用后仍由原生保存；组件故障可见且独立于主程序。
- 配置按字段更新，原子保存；安装、卸载和回滚保留用户数据。
- 测试与日常进程/数据隔离；合成模型调用与真实窗口验收分别记录。

## 已交付的本机预览版

2026-10-30，`0.9.0-preview.1` 已安装到现有 `D:\Backup\Documents\ChatGPT\codex双开\CodexDual-Control`，沿用原快捷方式、实例配置与偏好。正式公开版本的发布路径尚未切换，本次没有发布 GitHub Release。

- 主程序为 C# / .NET 10 + WinForms，运行时不再加载 PowerShell Runspace；复用原有 C# 控件。
- 完成监测合入后台任务，以文件变化监听和每 60 秒补扫替代重复全目录扫描。读取位置和去重信息从旧检查点迁入，支持半行、截断、替换和重启续读。大附件行按有界缓冲跳过，继续处理后面的完成事件；未核验的元数据仍拒绝处理。
- 原生标题适配通过 C# WebSocket/CDP 实现，Node、Python 不再是标题组件运行依赖。每次按已登记的 home/profile、PID、创建时间核验当前 Desktop；从验证后的进程链发现当前 CLI，支持已核验的提问桥接子进程链。
- 当前服务商明确只接受官方 Codex 客户端。默认由 C# 启动官方 CLI 进行一次受限标题生成；保留直接 Responses 传输供允许这种方式的渠道配置使用，不伪装客户端绕过限制。
- 每个新 CLI 在当前控制器进程首次使用时，先在临时 home 和回环模拟服务中检查工具数为 0、请求头传递正常，通过后才发送真实请求。升级后自动重新发现和检查，检查失败会显示原因。
- 原生弹窗仍由用户采用、编辑和保存；控制器新增独立标题工具，保存调用官方 `thread/name/set`，回读确认，避免直接写聊天数据库。读取标题时优先使用原生名称索引，避免将最初的问题误当成已修改的标题。
- 日常外部启动器仍是短时运行的 PowerShell 维护入口；安装、回退和诊断脚本也保留。提问桥接属于原实验功能，当前安装版本不匹配时保留原生作答。

## 验证与边界

证据目录：`E:\codex\codex双开\local-updates\dotnet-migration-20261030`。

| 检查 | 结果与证据 |
|---|---|
| C# 核心回归 | 22 项通过，`core-tests-large-records.json`；包括附件跳过、历史去重、旧检查点迁移、文件替换、UTF-8、路由、缓存、DPAPI |
| 原有配置回归 | `tests/Test-Core.ps1` 的 40 项断言通过；新增 TOML 读取接口保留原编辑行为 |
| 原生标题前端 | 20 个独立 DOM 场景通过，`renderer-tests.log`；覆盖手动输入、切换目标和迟到结果，不等同于真实原生弹窗验收 |
| 实际 WinForms 控件 | 6 个页面启动、绘制和退出通过，`package-ui-smoke.json`；截图在 `ui-screenshots` |
| 真实标题模型 | 合成输入生成成功、第二次命中缓存；`live-title-cli-2.json`、`live-title-with-compatibility.json`。没有发送真实聊天内容或改名 |
| 升级后运行时 | 重启后 Desktop 26.1027.3384.0 的 CLI 自动发现并通过离线探针，`compatibility-after-upgrade.json`；无模型调用 |
| 原生保存接口 | 在独立测试 home 中使用升级后的真实 CLI 改名、回读并恢复原名，`native-api-after-upgrade.json`；无模型调用 |
| 独立 Desktop 适配连接 | 旧一轮独立 Desktop 中实际连接并加载适配脚本；未完成真实重命名弹窗的完整交互。该完整客户端试验在用户重启后已无残留 |
| 安装和回退 | 测试目录完成安装、启动器语法检查、逐文件回退；`install-rollback-test.json` 与两份 `install-fixture-backup*/receipt.json` |
| 日常安装 | 配置、凭据、实例登记哈希保持；原 API Desktop/CLI PID 和创建时间保持；`daily-install-verification.json` |

当前 API Desktop 启动时没有新调试参数，原生重命名弹窗建议区标为“需要完整重启 API 版”。本次没有中断这个活动客户端。独立标题工具可用；原生弹窗的建议显示、采用、手动输入保护和保存后的侧栏刷新，仍需下次完整启动后的真实验收。自然任务完成提示、长期内存稳定性和全部窗口组合也没有被这次短期测试覆盖。

构建成功仍有旧控件及兼容代码的 nullable 警告；没有将警告当成全部消除。程序化创建控件不使用 WinForms Designer，因此仅对设计器序列化规则 WFO1000 作项目级排除。

## 性能结果

- 同一份 630,232 字节合成日志：Windows PowerShell 5.1 热运行 247.9–308.9 ms；C# 热运行 3.6–7.1 ms。只代表读取器，不代表整体应用提速。
- 重启前同一 30 秒观察窗口：旧控制器与通知进程私有内存合计约 227 MiB，独立状态的 C# 试运行约 22 MiB；CPU 时间分别约 1.063 s 和 0.125 s。两者都读取同一 API 日志；试运行没有启用原生标题挂接。
- 日常安装并导入旧记录、处理大附件后，新控制器观察值约 40 MiB，且没有常驻 PowerShell 子进程。该数值是运行快照，不能用于证明没有长期泄漏。
- 用户报告严重卡顿并重启后，进行了 30 分钟、600 次整机采样。CPU 平均约 7.0%、最高 32.9%；最低可用物理内存约 17.2 GiB。采样平均耗时约 10.8 ms / 3 s，已自动退出。
- 重启前系统日志仅发现意外关闭记录，未取得足以确认根因的证据。此前启动过独立完整 Desktop，可能增加负荷，但不能据此认定它导致卡顿。后续停止这类并行验证，当前采样未重现资源耗尽。

原始性能数据、操作时间标记和汇总在 `performance-after-restart/`。CPU 百分比按逻辑处理器数归一化；私有内存不等于物理内存占用；低频 GPU 计数器不能排除未被采到的瞬时停顿。

## 构建、安装和回退

```powershell
scripts\Build-DotNet.ps1 -DotNet <dotnet.exe> -OutputDirectory <package>
scripts\Install-DotNetLocal.ps1 -Package <package> -Target <existing-installation> -Backup <new-backup-directory>
# 上一行只做预检；本机安装使用显式 -Apply，并可指定已登记的外部 API 启动器。
scripts\Rollback-DotNetLocal.ps1 -Receipt <backup\receipt.json>
# 回退同样先检查哈希，再用 -Apply 执行。
```

本机构建 SDK 是验证 SHA512 后解压到证据目录 `toolchain/dotnet` 的 10.0.403，没有修改系统 PATH。包使用已安装的 .NET 10 Desktop x64 运行时。

原版备份及合并后的最终回退收据在 `daily-backup`，小修订的中间备份在 `daily-revision-backup`。最终收据保留原版文件哈希，并更新为实际安装文件的校验值。启动器只替换标题集成段，回退保留其他段。

安装目录的 `回退到PowerShell控制器.cmd` 可恢复原控制器和原标题启动段；不结束 Codex Desktop、不删除聊天。修改过的安装文件会阻止自动覆盖，修改过的用户设置保留。原标题启动段恢复后仍具有旧版本绑定的已知限制。
