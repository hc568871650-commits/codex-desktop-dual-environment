# API 通知接管与原版提问交互：接入检查点

检查日期：2026-09-27。显示设置已通过回归；隔离桥接原型及回退已完成模拟问答、真实 CLI 与 Desktop 加载验证，详见 [当前检查点](CHECKPOINT-NOTIFICATIONS-NEXT.md)。日常提问与全通知接管尚未部署。以下为接入调查及设计，不是完整原版功能验收说明。

## 本轮需求

- 同时提供独立窗口直接选择/填写回答，以及返回对应 Codex 任务作答。
- 保留原版提问功能，不把问题简化为“任务需要处理”的提示。
- API 通知统一经过控制器，官方端保持独立。
- 可选择短时间自动收起、自定义时间、常驻手动关闭和过渡动画。
- 收起窗口不代表回答、跳过、拒绝或审批；不能自动提交默认选项。

## 已核实的接入边界

1. 当前控制器 `src/CompletionReader.ps1` 只接收 `event_msg/task_complete`。日志不是双向交互接口，不能用于向运行中的提问提交答案。
2. 本机 Store 包是 `OpenAI.Codex 26.924.2738.0`。只读检查 `resources/app.asar` 中 `.vite/build/main-DAwJoFgo.js`，发现 `item/tool/requestUserInput`、`replyWithUserInputResponse`、`serverRequest/resolved` 以及 `thread-follower-submit-user-input`。这些内部实现的存在，不等于第三方插件拥有受支持的调用入口。
3. 被检查的桌面 app-server 启动参数含 `app-server`，没有 `--listen` 的 ws/unix 地址；其当前 CLI 帮助说明默认传输为 stdio。只读端口检查未发现桌面主进程或该 app-server 的 TCP 监听。未尝试注入进程、接管现有句柄、修改官方包或向真实聊天提交回复。
4. 当前 CLI 导出的 `ToolRequestUserInputParams` 包含 `isBlocking`、`questions`、`itemId`、`threadId`、`turnId`；问题包含 `id/header/question`、可选选项、`isOther`、`isSecret`。回答按问题 ID 映射到 `answers` 数组。导出证据在 `test-results/protocol-20260927`，由当前运行中 CLI 路径执行 `app-server generate-json-schema` 得到。
5. 桌面包还引用 `item/tool/requestOptionPicker`，但此次 CLI 导出的 `ServerRequest.json` 没有列出此方法。因此不能以同步提问协议的单元测试代替全部原版交互的验收。
6. 桌面通知管理器有 `notifications-turn-mode` 与独立的 permission/question 类别。其 `shouldSuppressNotification` 仅针对 turn-complete/agent-message。只关闭完成提醒不等于关闭全部原生通知，更不等于所有事件已经可靠转发。
7. 当前 `external` 启动路径会清理 CODEX_/OPENAI_/CHATGPT_/ELECTRON_ 环境变量；因此仅给控制器设置 `CODEX_CLI_PATH`，不能证明 API 桌面实例会经过桥接层。

官方协议参考：[Codex App Server](https://learn.chatgpt.com/docs/app-server)。文档描述双向请求、响应和已解决事件，但未证明第三方客户端可以附着当前桌面私有 stdio 连接。实现优先使用本机版本生成的 schema，并单独核验桌面新增交互。

## 下一阶段的具体方案

先在独立测试实例验证 API 专用启动桥接层，不直接修改日常启动器或运行中的实例：

1. 将 API 桌面到 app-server 的连接经由可回退的代理转发，保持官方端原启动路径。代理进程必须绑定已登记的 API home、profile、进程身份和单次连接 ID。
2. 控制器通过当前用户限定的本地管道接收结构化事件；不依赖公开网络监听，不写入密钥、完整聊天内容或敏感回答。
3. 问题按 instance/connection/request/thread/turn 关联。窗口提供问题分页或滚动、选项说明、自由输入、敏感输入隐藏和返回原任务。未接通回传时不提供假提交按钮。
4. 两个入口竞争回答时，以仍有效的请求为准；已解决、断线、任务停止、请求替换后立即禁用旧提交。重连不得把旧答案投递到新请求。
5. 单独验证异步提问、选项选择器、命令审批、文件审批、权限请求和 MCP 表单。无法识别的类别保留原生入口，不自动批准、不静默吞掉。
6. 只有事件覆盖与回传验证通过后，才在 API 专用配置中逐项抑制对应原生通知。不得修改共享 Windows 通知身份来同时静音两端。
7. 代理故障时保留可见的原生处理入口。不能保证自动回退的类别不得进入“完全接管”模式。

用户已授权这条路线的隔离验证，并要求保留回退脚本。它涉及启动链路调整和版本兼容维护，属于当前完成日志监听之外的架构变更。是否所有原生通知都能通过这条路线覆盖，仍须继续确认；不得提前标注“完全隔离”或“原版功能已还原”。

## 验收门槛

| 场景 | 必须验证 |
|---|---|
| 普通提问 | 选项和说明一致；自由输入准确；可多题；只在明确提交后回传 |
| 异步提问 | 任务继续运行时仍可回答；新问题与旧问题分别关联 |
| 两处回答 | 任一处回答后另一处关闭或禁用；不重复发送 |
| 关闭/超时收起 | 不取消请求、不替用户作答；待处理列表可重新打开 |
| 原版扩展交互 | 选项选择器、审批、敏感输入、MCP 表单分别验收 |
| 全通知接管 | 每类通知不漏、不重复；官方端不受影响；声音与点击目标正确 |
| 故障 | 代理/控制器退出、重连、Codex 更新后仍有可靠人工处理入口 |
| 实例隔离 | 官方/API 并行任务，各自问题和回答不串线 |

单元测试与模拟协议只证明局部行为。最终验收须在独立 API 桌面实例中产生真实提问并交叉核验回答、通知、任务归属；没有这一步不能部署为完整接管。
