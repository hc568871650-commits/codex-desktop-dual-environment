# 退出流程：验证记录

2026-10-09。当前要求：保留一次确认，确认后直接结束已核验的桌面实例，移除单独的强制结束按钮及正常关闭等待。原先的两阶段流程已被本次调整替代。

当前改动不使用 WM_CLOSE；首次确认明确告知直接结束及中断任务风险。Stop-InstanceForced 保留实例身份核验、当前宿主保护和桌面进程树范围。结束后至多等待 2 秒核实结果，提前退出即结束等待，不自动重试。渠道重启仍在确认实例停止后才应用。

## 当前直接退出版验证

- Test-ExitFlow.ps1：20 项通过（mock 边界，真实控件）。
- Test-ExitUi.ps1：7 项通过（退出等待与消息泵）。
- Test-Instances.ps1 -Integration：42 项通过（真实隔离进程、身份/归属、其他环境保留）。
- Test-Host.ps1 -ExitOnly：17 项通过；首次 Yes 结束顽固 fixture 小于 3 秒，取消保留，无第二次确认、强制按钮或结果窗。证据目录：`test-results/host-42f0d6c8dd164a37b05f39c753e79648 space 中文`，进程快照见 `process-preservation.json`。
- 首次 Host 退出流程检查通过，但最后“所有原 Codex 进程保留”断言失败，未保存差异，具体原因未确定。增加 before/after/changed 证据输出后，未修改或放宽原断言，进行一次重跑通过。不能将失败描述为已定位。
- mock 初次超时文案断言漏了环境名称前缀，修正测试后 20 项全部通过。
- git diff --check 通过。没有点击日常 Codex 的真实退出按钮。

## 前一版记录（已被替代）

以下为同日较早的两阶段方案及其验证证据，不代表当前交互。该版曾安装，后由确认后直接退出版替代。

## 行为

- 首次确认后尝试正常关闭；等待在面板内显示，无独立进度窗。
- 正常退出直接反馈，不弹结果窗。正常等待上限仍为 3 秒，未以缩短等待换取更快强制终止。
- 超时后退出按钮/托盘菜单变为强制结束；只有主动点击才确认，默认否。
- 强制操作绑定原进程身份，仍保留归属、启动时间、当前宿主保护。
- 残留数量在面板显示，悬停查看 PID/名称。渠道重启仍同步核验实例停止才应用。

## 证据

- `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-ExitUi.ps1`：7 项通过，临时进程验证正常退出、超时边界和消息泵。
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-ExitFlow.ps1`：19 项通过，模拟边界验证取消、超时、强制、PID 复用及渠道重启保护；真实 WinForms 控件。
- `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-Host.ps1 -ExitOnly`：16 项通过，隔离编译安装、实际按钮/确认框和可抛弃 GUI 进程。路径：`test-results/host-c9171cf089304a6f9c1e472241e93019 space 中文`。真实 Codex 进程身份在测试前后保持。
- `git diff --check` 通过。

较宽泛的 Test-Controller 在 singleton enforcement 断言失败（此前托盘、面板、诊断渲染已通过）；完整 Test-Host 在第二次启动转发断言失败，尚未进入关闭测试。原因未在本次范围内确定。退出专项通过不代表完整套件通过，也不代表日常安装已更新。
