# 0.3 开发检查点

范围已确认：双环境面板、API 渠道管理及 CCS 可选接入、登录自启动开关、分别改名和恢复默认。交接说明、多开、自动任务分发不在本版。

开发分支：codex/dual-experience-0.3。原工作分支 codex/instance-controller 干净，基线 c32bfcc。用户授权完成开发和成品打包；未要求发布或升级日常环境。

实现：
- src/TomlConfig.cs：保留非受管文本的保守 TOML 编辑器，拒绝重复键、结构冲突、认证冲突及外部 provider。
- src/Core.ps1：配置保留、文件事务回退；CCS 模式不注入原 DPAPI 密钥，检查设置目录漂移。
- src/Preferences.ps1：按稳定实例 ID 存储显示名称；面板位置及待生效提示；精确注册/移除当前控制器的 HKCU Run 自启动项。
- src/ApiManagement.ps1：渠道增删改、加密密钥与快照、恢复、CCS 目录核对/交接/返回；运行中选择渠道仅暂存，下一次启动时成套应用。
- src/Panel.ps1 和 Controller.ps1：新面板、名称对话框、渠道/CCS/备份三个页签、环境检查。左键显示记忆位置面板；右键菜单；关闭隐藏。SmokeTest 使用独立互斥锁，不干扰日常控制器。
- Configure.cmd 统一进入控制器配置界面，ControllerHost.cs 支持 --background 和 --config。

交付检查结果：核心40、实例39（真实WinForms进程）、安装卸载11、升级33、体验51、控制器3和编译EXE操作11，共188项通过。两个全新 Codex 实例同时运行、去重、重识别、清理及原实例保留也已通过。没有读写真实 CCS 数据库或使用真实 API Key。

成品版本为0.3.0，提供全量包与0.x升级包。tests/Test-Packages.ps1负责逐文件SHA-256核对、运行数据排除、实际0.2.0安装升级和完整包独立安装。运行记录保存在test-results，发布包不包含这些数据。没有发布远程版本或替换日常安装；功能与验证边界见VERSION-0.3.md和VALIDATION.md。
