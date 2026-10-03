# 通知更新检查点

> 历史维护快照：本文保留对应开发阶段的结果和失败边界，不描述当前安装或公开版本状态。机器路径、PID 和本机入口仅用于追溯，不能在其他机器直接执行；当前交付范围和验证结论以 [README](../README.md) 与 [验证记录](VALIDATION.md) 为准。

日期：2026-09-27。源码目录：`E:\codex\codex双开\codex-dual-controller-dev`。

## 目标与决定

用户要求增加原版提问界面、API 消息由本软件统一处理，以及可配置自动消失/常驻/动画。用户已明确提问需要同时保留独立窗口直接作答与返回 Codex 作答，目标是还原原版功能。

## 已实现，未部署

- 通知页新增“显示设置”：3/5/10/15/30 秒、自定义 1–3600 秒、常驻、动画开关。
- 沿用通知配置文件持久化，兼容旧配置，默认 15 秒无动画。
- 当前卡片和预览应用设置；悬停/操作暂停；淡出中交互或切常驻会恢复卡片。
- 显示设置保存、重新打开和卡片生命周期新增回归测试。
- 变更文件：`src/CompletionCard.cs`、`src/CompletionNotifications.ps1`、`src/WorkspacePages.ps1`、`tests/Test-CompletionNotifications.ps1`。
- 未改版本号，未提交、发布或替换日常安装；未关闭原生通知。

## 验证

- 专项检查：通知 45 项、通知开关 20 项、外观 15 项通过。
- 主代理已检查设置截图：`test-results/notifications-ui-29bef83486854e0cb1ea125c63b7b2c3/display-settings.png`。
- 完整回归 23 个套件全部通过：`test-results/validation-20260927-145301/summary.json`，包含编译宿主界面检查；主测试进程退出码为 0。
- 这些测试使用隔离测试配置/模拟实例，不能代替运行中的 API 桌面提问验收。

## 2026-09-27：隔离桥接与回退验证

用户已同意按 API 专用启动桥接路线先做隔离验证，并明确要求留下方便回退的脚本。本阶段不部署日常 API 环境。

- 原型源码位于 `experiments/notification-bridge`：stdio 代理、当前用户限定的命名管道、多题/选项/自由输入/敏感输入窗口、独立启动器和回退脚本。
- 答案需同时匹配 connectionId、requestToken、requestId、threadId、turnId。原生请求始终转发；外部作答成功后发送已解决事件。未知交互保留原生处理。
- 运行中 DISABLED 停止接受外部回答、保留原生通道；下一次启动不注入代理。默认回退不终止任务或删除任何数据。
- 可交付实验包：`E:\codex\codex双开\codex-controller-trial\notification-bridge-20260927-verified`，现已停用。
- 方便入口：`E:\codex\codex双开\codex-controller-trial\回退API桥接.cmd`。包内另有 `Rollback-ApiBridge.cmd` 和 `Start-WithoutBridge.cmd`。

验证证据：

| 检查 | 结果 | 证据 |
|---|---|---|
| 模拟协议传输 | 子代理执行 13 组通过，主代理审查关键并发/失效边界 | `experiments/notification-bridge/tests/Test-BridgeTransport.ps1`；最后测试产物 `C:\Users\Administrator\AppData\Local\Temp\bridge-transport-35e3cd69a9b341ac8dd7bf7a0ca540f3`，PASS 仅在执行输出中 |
| 实验创建与回退 | 主代理执行 12 项通过 | `test-results/bridge-recovery-8601209f5a944c20949cc10e9c7c1d9a/result.json` |
| 窗口实际选择/填写→管道→模拟服务 | 主代理执行 8 项通过，截图已检查 | `test-results/bridge-question-ui-a372b88bdd114bc0a9fb8e918d653039/result.json` 与 `question-window.png` |
| 本机真实 CLI 握手/读取/运行中回退 | 主代理执行 5 项通过 | 实验包内 `real-cli-validation.json` |
| 本机真实 Desktop 加载/回退/重新绕过 | 主代理执行 7 项通过 | 实验包内 `desktop-validation.json` |

真实桌面验证确认测试 profile 的主进程启动了唯一代理，代理启动预期 realCli，管道实例绑定正确；回退不终止当前测试桌面，随后关闭该实验进程树、绕过重启后没有代理。测试窗口均已关闭，未使用真实密钥或发送模型任务。

日常进程仍保持原启动时间：桌面 PID 26344、CLI PID 27496、控制器 PID 10868；未部署、未改官方包、未改日常启动器或原生通知设置。复查时未发现残留 BridgeProxy 进程。

## 2026-09-27：正式作答窗与控制器集成

用户确认继续完成正式 UI、接入控制器及验证。未替换日常安装。

- 新增 `src/QuestionWindow.cs`：统一深浅主题/强调色、无边框可拖动缩放、多题与长内容、选项卡片、自由和敏感输入、同一 token 草稿、失效禁提交。
- 新增 `src/QuestionBridgeClient.cs` 与 `src/PendingQuestions.ps1`：后台管道通信、服务进程路径核验、注册 API home/profile/程序哈希绑定、待处理状态、答案提交和断线/回退处理。
- `Controller.ps1` 接入生命周期与定时刷新，通知页加入“待处理 / 最近完成”“连接提问”“预览提问”；托盘新增待处理入口。
- 提问卡片复用时长/常驻/动画，收起卡片仍可从列表作答；正式作答窗操作时常驻。模拟测试验证原生已解决后禁提交。
- `Preview-Questions.cmd` 和 `scripts/Preview-Questions.ps1` 提供不操作真实任务的预览。单独预览关闭后进程退出已验证。
- 桥接实验包未改，回退入口仍有效并保持 DISABLED。

本阶段证据：

- 完整 24 套回归：`test-results/validation-20260927-154424/summary.json`，全部退出码 0。
- 完整回归之后的样式/预览/任务标题小改动：`tests/Test-QuestionWindow.ps1` 再次 18 项通过；`experiments/notification-bridge/tests/Test-ControllerQuestions.ps1` 再次 14 项通过。
- 最终集成证据与深浅截图：`test-results/controller-questions-a87a499d4796417193c90c41abd6894b`，含 `result.json`、`preview-dark.png`、`preview-light.png`、`question-dark.png`、`pending-dark.png`。
- 真实 CLI 工具回路（子代理执行，主代理检查代码和证据）：`C:\Users\Administrator\AppData\Local\Temp\real-cli-question-07146b63a9fb447e8a6f4c34bb2b8ff1/evidence.json`，另复制到 `test-results/real-cli-question-20260927-evidence.json`。真实 CLI 调用 request_user_input → 桥接答案 B → 第二次 Responses 请求包含答案 → turn/completed；模型响应来自本机 loopback fixture，共 2 次本机请求，无真实凭据或远端模型请求。
- 真实 CLI 复现入口：`experiments/notification-bridge/tests/Test-RealCliQuestion.ps1`；本机 fixture：`RealCliQuestionFixture.cs`。
- 集成中发现 Windows 默认编码会使虚拟服务误读 UTF-8，已将 `FakeAppServer.cs` 的输入/输出显式设为 UTF-8，并由最终 Unicode 回传断言验证。

## 2026-09-27：紧凑通知式作答与返回任务修复

用户反馈原作答窗过大，希望略大于通知卡片、位置也与通知一致；同时反馈返回任务会带出控制面板，要求不自动打开。

- 默认作答窗从 760×650 改为 480×380，隐藏任务栏项，按通知所在屏幕工作区右下角定位，20px 边距并避开任务栏。头部与底部压缩，多题内部滚动，仍可手动调整大小。
- `QuestionWindow.PlaceNearNotifications` 已覆盖负坐标与较小工作区；正式入口使用现有通知工作区，独立预览自动取当前屏幕。
- 原大尺寸保留为 `Preview-Questions-Expanded.cmd` / 预览脚本 `-Expanded`，供首次操作检查或调试。实际启动检查确认默认 480×380、展开 760×650，关闭后进程均退出。
- 源码确认 `Receive-PanelOpen` 在 TaskOutcome=Unsupported 或打开异常时会主动 Show-ControlPanel。现在通过 FromNotification 标记区别通知返回路径：不支持、目标错误或后台异常都只给独立角落反馈，不自动显示控制面板。普通面板操作原有行为保留。
- 无任务 ID 的通知也走同一来源标记。正式作答窗点击返回后收起自身，仅请求对应 API 任务，不提交答案。
- 专项检查：23 项紧凑作答窗、8 项通知返回分支、15 项控制器问答集成通过。最终集成证据：`test-results/controller-questions-9b1bef6fa3054b19aa67916c2fa118c7`，含紧凑深浅截图。
- 完整 25 套回归全部通过：`test-results/validation-20260927-160650/summary.json`，主测试进程退出码 0。
- 本阶段没有替换日常安装或改桥接回退包。用户实际遇到的那次点击尚未现场复现；修复覆盖了源码中已确认的自动弹出分支，并以异步工作测试验证。

## 2026-09-27：已授权实装 0.8.0

用户明确要求“实装”。本机控制器已从 0.7.0 升级到 0.8.0，已正常启动；未发布 GitHub。

- 实体目标：`D:\Backup\Documents\ChatGPT\codex双开\CodexDual-Control`，E 盘 CodexDual-Control 为其兼容链接。
- 旧控制器 PID 10868 正常退出；新控制器 PID 32760 报告 ready-tray。原有 Codex 进程全部保留。
- 117 项安装文件校验、4 项关键配置/启动器哈希保留检查通过；实际打开通知页、待处理页和小窗预览，并正常关闭预览；通知 worker 状态 running。
- 现有通知设置为启用、15 秒、动画关闭；外观偏好保留。实际安装没有 question-bridge.local.json，未自动启用真实提问桥接。
- 升级前配置备份、部署记录和独立恢复代码在 `E:\codex\codex双开\local-updates\controller-0.8.0-20260927`。
- 一键回退：`E:\codex\codex双开\回退控制器0.8.cmd`，真实备份及当前安装的回退校验已通过；升级/回退底层另有 33 项隔离测试通过。
- 自动快照：目标目录下 `upgrades\20260927-161800-73fbb7b5d96b4a34bea5e60368d3aadf`。
- 安装后的程序文件受快照哈希保护；不要随意编辑安装目录源码或清单，否则回退会为保护改动而拒绝覆盖。后续变更应继续走带备份的升级流程。

## 2026-09-27：显示时长 5 秒与 0.8.1 保存修复

用户确认提示会自行消失，但 15 秒偏长；已通过实际安装的设置界面保存为 5 秒，动画仍关闭。作答窗常驻策略未改变。

调整过程中发现已安装 EXE 的显示设置保存按钮报错：GetNewClosure 创建的回调作用域无法解析控制器函数，异常处理的 Show-Error 也无法解析。改为从 sender.FindForm 获取控件、使用原控制器作用域回调。新增编译宿主实际保存回归，42 项 Host 检查通过。

本机已更新为 0.8.1，当前控制器 PID 22104。实际 GUI 保存 5 秒成功，无 .NET 异常窗；安装清单、关键配置和通知 worker 检查通过。未重启 Codex。

- 部署与验证：`E:\codex\codex双开\local-updates\controller-0.8.1-20260927`。
- 回退入口：`E:\codex\codex双开\回退控制器0.8.1.cmd`，恢复程序到 0.8.0，保留用户通知设置。真实快照校验通过。
- 快照：安装目录 `upgrades\20260927-163648-f0e181396b44406b81a6bfba5c22b052`。
- 新增回归位于 `tests/Test-Host.ps1`，产物 `test-results/host-3e5f5064463942aa83420f923db21e79 space 中文`。

## 2026-09-27：0.8.2 连续计时修复

用户反馈已设 5 秒仍等待很久。确认配置已保存为 5 秒，但 CompletionCard 会因鼠标悬停或 ContainsFocus 暂停计时。现改为 Stopwatch 单调时间计时，普通提示不再因悬停/焦点暂停；明确的选择菜单仍可通过 PauseDismissal 临时暂停，作答窗不受影响。

- 0.8.2 已安装并启动，控制器 PID 32472；Codex 主进程 26344 / CLI 27496 保持原启动时间。
- 新增 `tests/Test-NoticeDeadline.ps1`：初始悬停、焦点同时为 true，提示 5016ms 关闭。
- 通知 UI 45 项、返回任务 8 项检查通过。实际已安装 EXE 的预览从出现到消失测得约 5012ms。
- 实装证据 `E:\codex\codex双开\local-updates\controller-0.8.2-20260927/verification.json`；安装清单和真实回退快照校验通过。
- 回退 `E:\codex\codex双开\回退控制器0.8.2.cmd`，恢复到 0.8.1。快照为安装目录 `upgrades\20260927-164214-b8df3ff400c54c18a13743d2afb8caf9`。

## 2026-09-27：0.8.3 通知圆角裁切

用户截图显示通知圆角边框外露出矩形背景。CompletionCard 原来只绘制圆角线条，没有设置实际窗口 Region；现将绘制边框和窗口裁切复用同一 GraphicsPath，并在尺寸变化时重建、释放 Region。

- 15 项原生窗口区域检查（四角排除、内部保留、不同尺寸）和 45 项通知 UI 检查通过。
- 已安装 0.8.3，控制器 PID 36708。实际已安装预览的 Win32 window region 确认四角被裁切。Codex 原进程未重启。
- 本轮开始时用户设置已为 10 秒、动画开启；更新前后比较保持一致，本轮未调整时长或动画偏好。
- 实测与回退资料：`E:\codex\codex双开\local-updates\controller-0.8.3-20260927`。回退入口 `E:\codex\codex双开\回退控制器0.8.3.cmd`，恢复到 0.8.2；真实快照校验通过。
- 快照：安装目录 `upgrades\20260927-165057-b145fe0564914755b05bb15f0a340349`。

## 尚未实现与下一步

- 控制器源码中的正式问答 UI 与管道集成已经完成。真实远端模型生成的提问、桌面原窗口同步、精确返回任务、异步扩展交互和 API 全通知隔离尚未全部验收，不能标记为原版功能已完全还原。
- 当前日常控制器已是 0.8.3；新代理已验证可由独立桌面启动并连接真实 CLI，但尚未在日常 API 启动链路启用。真实提问仍在原 Codex 中处理。
- 接入调查、版本差异、API 专用启动桥接方案与验收矩阵在 `docs/NOTIFICATION-BRIDGE-NEXT.md`。
- 下一阶段继续在独立实例验证真实提问与异步扩展，逐类覆盖之后，再考虑替换日常启动链路和抑制对应原生通知。届时必须备份真实被修改的启动入口并验证恢复；当前回退只针对本次实验，不能冒充历史全量恢复。
- 不要仅设置全局环境变量、修改共享 Windows 通知开关或写聊天日志来冒充接管；不要向真实聊天自动发送默认答案。
