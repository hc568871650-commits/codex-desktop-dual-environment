# 0.6.2 工作检查点

> 历史维护快照：本文保留对应开发阶段的结果和失败边界，不描述当前安装或公开版本状态。机器路径、PID 和本机入口仅用于追溯，不能在其他机器直接执行；当前交付范围和验证结论以 [README](../README.md) 与 [验证记录](VALIDATION.md) 为准。

目标：修复API最小化到任务栏后的单击恢复慢；保留625ms双击容错。

发现：API根进程6848一直Running。旧打开路径重复做全量进程/Store发现及CIM身份核验。一次真实最小化配对测量恢复流程1081.9ms→29.9ms（不含625ms；后一条脚本被Windows拒绝抢占前台，但已恢复窗口，PID不变）。

实现：Native.FocusKnownVisible实时核验pid/start/path/command/home/profile，仅对缓存匹配且唯一可见主窗口快速恢复。Panel缓存命中直接使用，不启动后台发现或外部启动器。隐藏、多窗口、缓存缺失/失效继续旧流程。ControllerWork状态输出加实例标识。

专项：tests/Test-FastRestore.ps1真实夹具17项通过；实例集成42项通过。Test-All的20个套件全部通过，日志test-results/validation-20260926-214956。

剩余：0.6.1→0.6.2包验证、依据既有本机替换授权更新控制器，保留原Codex进程和回退快照。当前本机仍0.6.1。
