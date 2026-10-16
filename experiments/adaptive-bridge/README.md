# API 提问桥接自动适配

本地候选功能，独立安装；不包含在标准控制器完整包或升级包内。2026-10-16 交接时已准备兼容候选并更新下一次启动配置，状态仍为 `waiting_restart / COMPATIBLE_PREPARED`；这只是交接时间点记录，**真实 Desktop 完整重启后的组合体验尚未人工验收**。

实验环境需要 Windows PowerShell 5.1、Codex Desktop/CLI 和控制器；与标题增强、守护兼容组件组合使用时还需 Node.js、Python。安装脚本仍含本机路径默认值及特定启动器模板约束，需要维护者审查和适配，尚不是面向所有用户的一键安装。守护兼容补丁也应独立交付，不属于标准控制器包。

## 行为

- 从已经核实的 API Desktop 实际后台发现 CLI。只接受直接子进程，或经生产绑定验证的单层 BridgeProxy 链，不从 PATH 或普通版推测。
- 新的 Desktop、CLI、代理或兼容测试程序会使旧缓存失效。使用空 Home、临时线程和本地 Responses 模拟接口验证同步提问、异步提问、多连接，以及答案回传后继续执行。
- 不调用供应商模型，不复制认证，不自动重启 Desktop。测试进程进入独立 Windows Job Object，退出或超时一并结束其子进程。
- 通过后生成独立版本目录。只有下次 API 完整启动、旧代理退出后才晋级登记。未知协议或失败保留原生入口，失败测试有冷却。
- 已禁用的功能不会因升级自动开启。控制器仅在没有待回答问题、未完成提交、排队结果、所有权移交、隐藏草稿和旧代理时刷新连接。
- 完成通知沿用现有日志读取、去重和断点；本次不重置历史。健康诊断新增适配状态，验证通过不等于真实连接或通知送达。

## 构建及验证

使用 Windows PowerShell 5.1：先运行 `Build-Fixture.ps1`，再由 `../notification-bridge/Build-Bridge.ps1` 构建代理。`Invoke-Compatibility.ps1 -CliPath ... -ProxyPath ... -OutputDirectory ...` 生成三项兼容报告。

从仓库根目录运行实验测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments/adaptive-bridge/tests/Test-AdaptiveBridge.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments/adaptive-bridge/tests/Test-AdaptiveIntegration.ps1
```

实验核心测试与依赖一起留在实验目录，仅源码检出包含这些入口。控制器回归包含 `../../tests/Test-QuestionRegistration.ps1`、窗口及通知测试。真实协议 fixture 使用真实 CLI 和本地 Responses 模拟接口，不调用供应商模型，不能替代实际 Desktop 的前后台及用户操作验收；标题建议实际生成则会调用用户现有供应商 API。

2026-10-16 交接记录中，自适配核心 30 项、启动集成与回退 15 项通过；Desktop `26.1007.9446.0` 对应 CLI 的同步、异步与多连接协议检查通过。以上是交接时本机分项证据，不代表最终发布源码、ZIP 或 CI 已通过，也不能推广为所有 Codex 版本兼容。临时证据可能清理，最终交付前应复验。

## 安装与回退

`Install-AdaptiveBridge.ps1` 默认仅准备；传入当前启动器 SHA256、已审查代理、源目录和安装目录。`-Apply` 验证准备产物后只改本功能对应的启动器片段和适配登记，不重启 Desktop，也不立即改运行中的问答登记。

`Rollback-AdaptiveBridge.ps1 -Installation <安装目录>` 先预检；加 `-Apply` 执行。回退保留当前问答所有权，下一次启动明确走原生 CLI；仅撤销本功能片段，保留标题增强和其他后续修改。目录内 `DISABLED` 也可阻止后续适配/启用。

## 人工验收清单

1. 在手头任务结束后正常完全退出 API 版，再通过现有启动器打开。仅关窗口到托盘不算完整退出。
2. 控制器诊断应从“等待下次启动”转为已验证绑定；待处理页收到有效快照后才能确认连接。
3. API 在后台时触发选项题：核对通知只出现一次、选项/其他输入可作答、提交后原任务继续。
4. 关闭问题窗口后重新打开，核对草稿仍在；返回 Codex 后使用原生入口，确认没有两边重复提交。
5. 同时有两条聊天提问时，核对答案不会串到另一条聊天；断线期间不自动重发。
6. 完成一条任务，核对完成通知、点击返回和去重；普通版保持独立。
7. 打开重命名，核对标题建议仍可生成、采用并手动保存。
8. 若遇到新协议失败，应能继续使用原生提问，诊断显示“需适配”，不能卡住启动。

不保证对未来任意协议自动修复。已覆盖协议的版本变化可以自动验证和重新绑定；未识别的变化明确降级并保留证据。
