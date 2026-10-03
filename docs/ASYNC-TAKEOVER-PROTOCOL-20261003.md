# 实验提问接管协议（2026-10-03）

## 范围与结论

实验代理同时识别传统 `item/tool/requestUserInput` 和异步 `agentMessage.questions`。二者协议不同：传统提问回复原始 JSON-RPC ID；异步提问通过 `turn/steer` 发送带题目身份的文本。默认保持既有镜像模式；只有实验 `bridge.config.json` 显式设置 `takeoverQuestions:true` 且问答客户端持续续租，才抑制对应原生问题投影。未知消息保持透传。

本修改没有替换日常安装、修改 WindowsApps 包、启动 Desktop 或调用远端模型。协议状态只在代理内存；代理重启后不根据旧数据库推测问题所有权。

## 本地证据

审查对象为 Desktop `OpenAI.Codex_26.930.2377.0_x64__2p2nqsd0c76g0/app/resources/app.asar` 和 CLI `be3fd7e5c1969ff6/codex.exe`。ASAR 按索引只读选定代码文本，没有全量解包或读取聊天题目、答案、认证数据。CLI `app-server generate-json-schema --experimental` 输出位于 `test-results/protocol-audit-20261003`。

协议 schema 的关键位置：

- `ToolRequestUserInputParams.json:70-95`：`isBlocking,itemId,questions,threadId,turnId`；`autoResolutionMs` 已弃用。
- `ToolRequestUserInputResponse.json`：`answers` 映射为题目 ID → `{answers:string[]}`。
- `v2/ItemStartedNotification.json:14-33`：异步题目 `{title:string,options?:string[]|null}`，只有 `title` 必填。
- `v2/ItemStartedNotification.json:837-902`：`agentMessage` 保持 `id,text,type`，可有 `delivery,phase,memoryCitation,questions`，`questions` 是 nullable 异步题目数组。
- `v2/ItemStartedNotification.json:1939-1958`：通知 params 包含 `item,threadId,turnId`；`item/completed` 具有同类 params 和 item 结构。
- `v2/TurnSteerParams.json:299-326`：必填 `expectedTurnId,input,threadId`。`expectedTurnId` 是服务端当前活动 turn 的前置条件，失配必须报错。
- `v2/TurnSteerResponse.json`：成功结果 `{turnId:string}`。

压缩包内 JS 以文件名和字符偏移定位；偏移不是行号，也不是磁盘字节偏移：

| 文件 | 偏移 | 发现 |
| --- | ---: | --- |
| `.vite/build/bootstrap-CYu4H4X5.js` | 881560 | 传统 RPC 写入 conversation.requests 并调用 onUserInputRequest |
| `webview/assets/app-initial-1da99842592d.js` | 9547683 | 传统 question 事件生成原生 `kind:question` 通知 |
| `webview/assets/app-shared-ac32c0d1413b.js` | 3511632 | `agentMessage.questions` 转为题目；合成 ID 为 `JSON.stringify(["request_user_input_async",item.id,index])` |
| `webview/assets/app-initial-1da99842592d.js` | 9540967 | 异步通知监听 `item/started`，识别问题项并读取活动 turn/题目状态 |
| 同文件 | 9542421 | 通知还要求未提交、未跳过、同一 turn 且 turn `inProgress`，以及通知策略允许 |
| 同文件 | 9543071 | 异步 `kind:question` 通知；导航到 `openRequestUserInputAsyncQuestion` |
| 同文件 | 1306854 | 问答 UI 有独立的本地 30 秒 deadline 状态 |
| `webview/assets/app-primary-85e5c56f1696.js` | 504818 | 原生提交调用 `steerTurn`，trigger 为 `send_user_message_async_question` |
| `webview/assets/app-shared-ac32c0d1413b.js` | 4773744 | 原生回答文本 wrapper 及回复解析 |
| 同文件 | 4774085 | 从已接受的 userMessage/steeringUserMessage 识别已回答问题，关联 questionItemId |

异步通知并非只要出现 `questions` 就一定弹出。题目存在只是第一层条件；还需要活动 turn、通知策略、stream role 非 follower、题目未回复/跳过和同一 turn 状态。传统与异步原生通知是两条不同入口。

## 回答格式与去重

异步题目原始 ID 为 agentMessage.id，题目索引从零开始。回答的 questionItemId 必须使用数组 JSON 字符串，与原生一致：

```json
{"questionItemId":"[\"request_user_input_async\",\"item-id\",0]","question":"原题title","answer":"用户答案"}
```

发给 `turn/steer` 的单个 text 输入格式：

```text
<send_user_message_question_reply>
[{"questionItemId":"...","question":"...","answer":"..."}]
</send_user_message_question_reply>
```

原生从 turn.items 中提取此 wrapper，只认单个 text 输入；对于 steeringUserMessage，只有 `status:accepted` 才计为已回答。它同时考虑 client/server 消息 ID 以避免同一次 steer 和后续 userMessage 重复，并按项顺序保留最近的回答。代理采用内存的精确 `(threadId,turnId,itemId)` 身份和成功 RPC 结果来去重，不扫描历史文字猜测答案。

## 项目客户端接口

配置与原有 `realCli/apiHome/instanceId/pipeName` 绑定不变；`CODEX_HOME` 必须与已配置 API home 完全匹配，错误 home 不能启动该代理。`takeoverQuestions` 缺省/false 保持旧镜像。

1. `snapshot` 增加 `takeoverReady:true`，续五秒单调时钟 lease；建议每秒心跳。`takeoverReady:false` 立即撤销 lease 并恢复未提交的原生问题。省略字段仅查询，不续租。
2. snapshot 外层增加 `takeoverEnabled,takeoverActive`。每个 pending 保持旧身份字段，增加 `kind:"traditional"|"async"`、`delivery:"exclusive"|"mirror"`、`outcomeUnknown:bool`。
3. async 题目规范化为现有编辑器结构：`id` 是索引字符串，`question` 来自 title，options 为 label/description，允许其他自由回答。未知/不合法题目形状不接管，交回原生。
4. `answer` 保持原字段：`requestId,connectionId,requestToken,threadId,turnId,answers`。传统答案回复原 ID；异步生成内部唯一 ID 的 `turn/steer`。收到无 error 且 result.turnId 与目标相同才答复 `ok:true` 并移除 pending。
5. `release` 使用同样完整身份字段，不只按 token 或 thread 模糊匹配。成功恢复保存的原生事件、移除外部 pending 并将该身份记为 released，不再重新接管。收到成功后客户端再导航到 Codex。

异步答案等待最多 1200ms；等待期间 `Monitor.Wait` 释放 Gate，其他 pipe 连接可续租和查询。超时返回 `outcome-unknown`；不会自动重发，再次回答和 release 都拒绝。晚到的成功结果清除 pending；明确 error 返回 `steer-rejected` 并保持身份供重试。无 error 但成功 result.turnId 缺失/不符也属于 `outcome-unknown`，不是可安全重试的明确拒绝。状态不明时 UI 应禁提交、禁返回原生。

## 原生抑制和恢复

- 传统 exclusive 请求在解析、验证所有权之后才决定是否写给前端，不再先透传后镜像。
- 传统题目必须非空，ID 非空且唯一，question 可呈现；可选布尔值、header、option 类型均验证。未知富字段/空题/重复 ID/错误类型全部原样交给 native，不放外部 pending。异步只接管 title/options 字符串规范，未知题目扩展也放行。
- `takeoverQuestions:true` 但无 ready lease 时，传统/异步问题直接归 native，不建立镜像外部入口。已经交给 native 的精确身份记入 released；客户端晚连之后收到同题 completed 或重放也不抢回。仅 config 缺省/false 的旧镜像模式保留双入口及原有仲裁。
- 异步 exclusive 请求保留整个 agentMessage，仅前端投影设 `questions:null`；文本、id、phase、delivery 等不丢失。后端持久内容未改动。
- exact identity 已持有/已回答的 `item/started`、`item/completed` 重放不产生新 pending。传统相同身份/请求 ID 重放也不重复。
- 对前端 `thread/read,resume,turns/list,timeline/list` 关联响应，只沿已知投影结构处理该精确 thread/turn/item；未知问题、其他 thread/turn、重启无内存记录或无 lease 时保持原样。没有全局删 questions。
- 每 100ms watchdog 检查 lease 与 DISABLED，无需客户端再查询也能恢复隐藏但尚未提交的原始事件，并清除外部入口。
- in-flight/未知结果的 steer 不能在 lease 失效或 DISABLED 时盲目恢复第二作答入口。它保留等待确定结果；成功则消除，明确失败才恢复原生。若服务端永远不返回，当前进程内保持歧义状态，必须由明确断线/turn 结束或人工恢复处理，不能自动重复提交。
- `turn/completed/interrupted` 清除对应 pending，阻止该 turn 后到的新问题被捕获。未知 RPC/通知始终透传。DISABLED 后延续已有子进程和 stdio 透传，不改模型任务。

## 已验证与限制

`Test-Takeover.ps1` 使用完全本地模拟 app-server 和唯一实验 home，覆盖 ready/no-ready、晚连不夺回、传统空题/重复 ID/缺题/错误 option/flag/富字段放行、默认镜像、traditional/async、主文本完整、身份绑定、返回原生、失租 watchdog、暂停、DISABLED、成功/明确错误/未知结果/错误 turn 成功封包、重复/竞答、等待时其他 pipe 响应、晚到成功、已答重放、历史精确过滤、未知消息、已结束 turn 和错误 home。最新 79 项通过：`test-results/takeover-32dce85ec69d46fb9627bac17db30883`。

原 `Test-BridgeTransport.ps1` 的 13 个场景通过，验证旧镜像、native-first、断线重连、启动/运行 DISABLED、CLI子命令、ID重用/字符串ID、完成/中断与同配置并发回退。该次输出：`C:/Users/Administrator/AppData/Local/Temp/bridge-transport-797b406c5dfc4fb4b603654d430493ec`。

主任务的真实当前 CLI + loopback Responses fixture 已证实异步完整链路，`test-results/real-takeover-async-tools-20261003/evidence.json` 记录 `success:true,mode:async,requests:3,chosenTool:request_user_input_async,nativeQuestions:0,bridgeAnswerAccepted:true,answerReachedRuntime:true`。该 fixture 从当前本机 gpt-6-astra 的实际请求中读取工具定义；工具位于 `input[type=additional_tools]` 而非单独的 `body.tools`。最初 fixture 未识别 additional_tools 导致“未找到工具”，不证明 CLI 或模型不支持异步提问。没有据此更改真实模型或凭猜测修改日常特性开关。

这些包含协议行为、编译及真实 CLI 的本地 loopback 证据，不能宣称所有真实 Desktop 弹窗、系统通知、多窗口 follower、未来 schema 或所有 canonical 历史路径已端到端验证。原生 wrapper 是当前版本内部约定；版本变化需重新核对。最终同步/异步 CLI 与控制器 UI 的额外验收由主任务单独记录。本次没有真实远端模型收费请求。
