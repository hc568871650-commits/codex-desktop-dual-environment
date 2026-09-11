# 开发检查点（历史记录）

以下记录为早期开发阶段快照，最新结果以 VALIDATION.md 后续补验章节为准；本次发布授权已取代开发阶段“不推送或发布”的限制。

目标：Windows 双环境部署与托盘实例控制；独立 worktree codex/instance-controller。原始环境只读，不推送或发布。

实现：CIM/Windows 命令行/只读 CODEX_HOME/创建时间身份核验、每实例互斥锁、WinForms 托盘、窗口选择与恢复、正常退出和二次确认强制退出、残留报告、部署/注册/保留数据卸载、DPAPI 和固定图标。

结果：核心 40、实例 39、部署 11、托盘 2 项检查通过。真实 Codex 两个独立测试实例同时运行、重复去重和重新识别通过；前台切换被 Windows 拒绝，正常关闭后驻留。测试实例强制清理尚待用户确认。原有工作实例未操作。

详见 VALIDATION.md 与 NOTIFICATIONS.md。最终 NUL 启动实现通过 WinForms 回归，真实 Codex 回归尚待。源码可审阅，无发布动作。
