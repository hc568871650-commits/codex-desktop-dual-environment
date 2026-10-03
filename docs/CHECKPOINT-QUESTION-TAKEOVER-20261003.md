# 提问接管与窗口行为实验

> 历史维护快照：本文保留对应开发阶段的结果和失败边界，不描述当前安装或公开版本状态。机器路径、PID 和本机入口仅用于追溯，不能在其他机器直接执行；当前交付范围和验证结论以 [README](../README.md) 与 [验证记录](VALIDATION.md) 为准。

2026-10-03（Asia/Shanghai）。用户明确要求完整接管：项目小窗负责提问，API 原生重复提问和通知不再出现；同时支持控制台和作答窗的聚焦、不聚焦及置顶行为。本轮仍在独立实验环境交付，未替换日常安装。

## 实现

- 通知页新增“窗口行为”。控制台可选择显示并聚焦或显示但不抢焦点；置顶独立设置。
- 收到问题可选择先显示提醒、直接显示小窗但不抢焦点、直接显示小窗并聚焦；作答窗置顶独立设置。已在另一问题中编辑时，新问题不会直接覆盖当前编辑内容。
- 不抢焦点采用一次性显示策略；若 Windows 显示/恢复把焦点错误交给自身，则立即归还此前前台窗口。没有持续轮询抢焦点，用户点击后仍可正常输入。
- 实验代理同时接管同步 `request_user_input` 和异步 `request_user_input_async`。同步原始请求不再发送给原生界面；异步仅移除前端问题交互字段，保留消息文本及后端原始历史。异步答案使用当前 turn 的受约束输入通道，成功确认前不报告提交完成。
- 接管限定已绑定 API home/profile、已核验二进制及客户端在线租约。无客户端、未知问题结构或已交给原生的问题继续由原生处理，不在晚连接后抢回。
- 服务失联或停用时，未提交的隐藏问题恢复原生入口。未知提交结果保留草稿、禁重复提交，不自动猜测成功或重发。
- “返回 Codex”先向桥接释放当前问题，确认原生入口恢复后再执行原有导航。精确跳转能否被当前 Desktop 接受仍是独立验收项。
- 暂停/关闭提醒只隐藏项目提示，仍保留已接管的待处理问题，不重新放出原生通知。

## 验证

| 层级 | 已验证结果 | 证据 |
| --- | --- | --- |
| 完整回归 | 28 套全部通过 | `test-results/validation-20261003-015618/summary.json` |
| 聚焦与层级 | 139 项，实际前台 HWND 与原生置顶标志，含重复显示、隐藏重开和最小化恢复 | `test-results/window-behavior-3f91401e93b74cd88bfdda99d65db956/test.log` |
| 编译控制器 | 46 项，设置实际保存及恢复，其他偏好保留 | `test-results/host-b8a6d629bc6a48f7bb8fcf2b25e9ca07 space 中文`；完整回归也包含该套 |
| 旧提问交互 | 20 项，新增自动聚焦/不聚焦问题显示 | `test-results/controller-questions-5909f23ea4154dd1abbd1852d1fe9419/result.json` |
| 接管协议 | 79 项，含在线判定、晚连不夺回、未知结构放行、历史精确过滤、回退与答复歧义 | `test-results/takeover-32dce85ec69d46fb9627bac17db30883` |
| 旧桥接兼容 | 13 组协议场景通过 | 见 `ASYNC-TAKEOVER-PROTOCOL-20261003.md` |
| 作答窗接管集成 | 21 项，真实控件、答案编码、先恢复再导航、超时草稿、迟到确认、暂停语义 | `test-results/controller-takeover-2a39edfc40ac4b70807beb8261cb90a1/result.json` |
| 当前真实 CLI 同步接管 | 2 次本机响应请求；答案进入引擎；任务完成；原生问题数 0 | `test-results/real-takeover-sync-final-20261003/evidence.json` |
| 当前真实 CLI 异步接管 | 3 次本机响应请求；实际工具 `request_user_input_async`；答案进入引擎；任务完成；原生问题数 0 | `test-results/real-takeover-async-final-20261003/evidence.json` |

真实 CLI 为 `be3fd7e5c1969ff6`。所有模型响应来自本机 loopback fixture，没有发送远端付费模型请求。异步 fixture 最初没有读取新版 `input[type=additional_tools]`，因此工具发现失败；修正后通过。早期失败证据保留，不作为桥接成功记录。

上述结果覆盖控制器 UI、协议及真实引擎；没有宣称真实 Desktop 的所有多窗口、系统 toast、历史恢复路径和审批表单均已验收。命令/文件审批与未知新协议保持原生处理。完整协议依据见 `ASYNC-TAKEOVER-PROTOCOL-20261003.md`。

## 独立交付

目录：`E:\codex\codex双开\codex-controller-trial\question-takeover-20261003`。

- `Open-ExperimentalController.cmd`：打开独立控制器；通知 → 窗口行为可选择策略。
- `Preview-PassiveQuestion.cmd`：三秒后显示不抢焦点、置顶的演示问题。
- `Preview-FocusedQuestion.cmd`：三秒后显示聚焦、置顶的演示问题。
- `Start-TakeoverTrial.cmd`：启用实验桥接，启动实验控制器后台服务和独立 Desktop。
- `Rollback-ApiBridge.cmd`：只停用本实验桥接，不结束日常任务。
- `Start-WithoutBridge.cmd`：用相同实验 home/profile 绕过桥接启动。

交付默认提问小窗为“不抢焦点并置顶”，控制台为“显示并聚焦、普通层级”。实验使用空 home/profile，不复制日常认证、密钥或聊天；没有绑定日常 0.8.3。源码版本标签仍为 0.8.3，未作为新正式版本发布。

生成入口在源码 `experiments/notification-bridge/New-TakeoverTrial.ps1`，要求新目录。二进制变更后应生成新实验并重新验证，不能直接替换已固定哈希的代理。
