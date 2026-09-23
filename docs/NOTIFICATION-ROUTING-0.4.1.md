# 0.4.1 通知分流调查与待确认方案

## 用户目标

API 端任务完成通知点击后进入 API 端，官方端通知仍进入官方端；控制器托盘左键直接打开或找回 API 端。精确定位任务与定位实例需要分别验收。

## 2026-09-23 本机只读证据

检查对象为 Store OpenAI.Codex 26.917.6896.0。未改安装包、注册表、真实配置或运行中的进程。

- AppxManifest.xml 只有一个 Desktop 应用身份 App，注册同一个 codex 协议。
- app.asar 内 bootstrap-DwqRMhlU.js 的 setAppUserModelId 使用按发行渠道固定的标识；生产渠道为 com.openai.codex，没有按 CODEX_HOME 或 Desktop profile 区分。
- main-Bx5zswAj.js 的任务通知通过 Electron Notification 创建。该处传入标题、正文、声音、动作等，再在进程内注册 click 回调；未携带控制器实例 ID 或 profile，也未使用控制器协议。
- Electron Windows 官方实现对 Desktop Bridge 使用不传 ID 的 CreateToastNotifier，走包身份。用户配置目录隔离不会自动产生新的 Windows 通知身份。此官方代码用于解释机制，不冒充已确认本机 Electron 逐行版本一致。
- 当前本机用户配置的 API 角色为 external；仍由原启动器启动。同一 Store 程序被两个环境复用。通知因此具备共用 Windows 身份的条件，与用户报告的误唤起官方端吻合。
- 本机近期 API 任务日志存在明确 event_msg/task_complete 事件。只核对事件类型与计数，未输出对话内容；它为独立完成通知提供候选信号，但还没有实现或完成监听可靠性验收。

结论：已定位到共享通知身份这一关键机制；尚未人工重现点击原生通知并记录目标 PID，不能把源代码分析称为端到端修复。单纯改图标、托盘或快捷方式无法保证分流。修改 codex 全局协议会影响其他入口，而且这些原生任务通知不是控制器协议通知，因此不采用。

## 推荐：控制器独立通知（等待用户确认后实现）

1. 控制器分别监听两套已登记 home 下明确的任务完成事件，不用“长时间没日志”猜测完成；默认跳过启用前的历史事件，按实例和完成事件去重。
2. 通知由控制器发出，携带可校验的实例关联；只展示必要信息，不拷贝答案正文或凭据。
3. 点击后沿用既有实例身份核验、启动/找回逻辑，固定进入发出通知的那一端；不能确认归属时明确失败，不默认转官方端。
4. 精确跳转任务作为单独能力验证；未证实前仅承诺打开对应端。
5. 新增启停选项和持久化监听状态；异常/格式变化时停用相关信号并提示，不干预正在运行的任务。
6. 启用时需要关闭对应端的原生任务完成通知以避免重复。不会改写已发出的旧原生通知，也不会把原生通知错误跳转描述为已修复。

这会增加通知监听和设置，属于相对原控制器的架构调整，按用户 AGENTS.md 第7条等待路线确认。确认之前只推进已经明确授权的托盘改动。

## 保留原生通知的路线

需要由官方程序支持按实例注册通知身份/激活回调，或为 API 端维护独立的应用身份和激活链路。后者涉及独立运行时、更新兼容与安装维护，不能当作一行启动参数修复发布。当前未创建、复制或修改这类程序。

## 官方参考

- Microsoft AppUserModelID 与通知：https://learn.microsoft.com/en-us/windows/win32/shell/enable-desktop-toast-with-appusermodelid
- Electron Notification 与 click/activation：https://www.electronjs.org/docs/latest/api/notification
- Electron Desktop Bridge 通知身份实现：https://github.com/electron/electron/blob/main/shell/browser/notifications/win/windows_toast_notification.cc

以上调查仅适用于已检查的本机版本，未来官方更新需要复核。