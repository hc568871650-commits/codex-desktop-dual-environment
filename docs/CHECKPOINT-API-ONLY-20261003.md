# API 专用触发修复与隔离实验

> 历史维护快照：本文保留对应开发阶段的结果和失败边界，不描述当前安装或公开版本状态。机器路径、PID 和本机入口仅用于追溯，不能在其他机器直接执行；当前交付范围和验证结论以 [README](../README.md) 与 [验证记录](VALIDATION.md) 为准。

日期：2026-10-03（Asia/Shanghai）。当前阶段：源码修复、隔离验证；未替换日常安装，未发布版本。

## 目标与原因

用户要求项目的任务提醒、问题和其他自动功能只能由 API 版触发，原版不应触发。用户随后授权“可以实验”。

现场确认日常控制器仍是 0.8.3，实体目录为 `D:\Backup\Documents\ChatGPT\codex双开\CodexDual-Control`。API Desktop 与官方 Desktop 使用同一程序但不同 profile；应以登记的 home/profile/instanceId 区分，不能按进程名或 Desktop 来源标签判断。

发现的实际缺陷：

- 完成监听器主动遍历两边的 sessions，队列消费者也接受官方事件；这不是偶发误判，而是旧实现的双端通知行为。
- 日常安装没有 `state/question-bridge.local.json`，作答窗口未接入日常真实问题。不能把预览小窗或隔离测试通过当成已接管。
- 作答窗没有置顶属性，会被普通桌面窗口盖住。
- 提问连接临时失败会禁用当前作答窗；恢复后旧实现只刷新列表，不恢复同一问题的提交能力。

## 已做的源码修复

- 唯一登记 API 实例判定供自动功能使用；原版手动打开、退出和目录管理保留。
- 监听只扫描 API；兼容旧双 home 检查点，验证原绑定后过滤官方记录，保留 API offset 和轮次去重，不重置历史。
- 生产者、队列消费者、直接卡片入口、通知返回任务入口均拒绝非 API 事件。
- 托盘、快捷面板和通知页在计数及分页前过滤非 API 最近记录。
- 作答窗置顶；连接恢复后仅在可信快照仍包含相同 requestToken 时恢复草稿与提交，不自动发送答案，不恢复已解决或已替换的问题。
- 提问提示遵守通知关闭/暂停设置，API 绑定失效时停止接收。

## 验证状态

- API 监听 40 项、通知 49 项针对性检查通过。
- 控制器提问集成 18 项通过，含短暂断线状态注入、同 token 恢复、草稿保留、回传、原入口解决、回退及实例绑定拒绝。
- 当前实际 CLI `be3fd7e5c1969ff6` 配合本机 Responses fixture 通过提问、桥接作答、答案到达运行时及继续完成；2 次请求均为本机 fixture，未使用真实密钥或远端付费模型。
- 完整 27 套回归全部通过，含编译宿主 42 项。首次运行在作答窗新增第 24 项后因旧总数断言 23 停止；修正总数后从该套继续执行，其余已通过套件未重复运行。保留 initial-summary 和首次日志，汇总 summary 为 27 个独立套件。
- 当前 Desktop 26.930.2377.0 独立 home/profile 启动及回退：7 项通过，实际核验管道服务 PID、实验 Desktop 父进程、真实 CLI 子进程和原生绕过启动。实验最后停用桥接并关闭自有窗口，模型请求为 0。
- 旧桌面实验曾在“所有同路径代理恰好一个”的断言失败；测试现改为通过内核查询实际管道服务 PID，再核验路径、app-server 参数及父子关系，避免短时 CLI 探测进程干扰身份判断。

关键证据：

- `test-results/controller-questions-7e1aa7dfe7ca4491883bf7b51737e094/result.json`
- `test-results/api-only-real-cli-20261003/evidence.json`
- `test-results/validation-20261003-010606/summary.json`
- 新隔离桌面目录：`E:\codex\codex双开\codex-controller-trial\api-only-20261003`
- 桌面实验结果：上述目录的 `desktop-validation.json`。
- 独立控制器：上述目录的 `Controller`，使用实验专用的两个空环境登记，不连接日常聊天；`Open-ExperimentalController.cmd` 直接调用它的 EXE 和独立配置，不走日常安装发现入口。

## 试用入口

打开 `E:\codex\codex双开\codex-controller-trial\api-only-20261003\Open-ExperimentalController.cmd`，在通知页预览通知或提问界面。关闭控制器即可结束预览。实验目录的两个环境均独立于日常环境。

桥接实验保持 `DISABLED`。本次已经验证启动/回退，不要求用户登录或付费发问才能查看小窗预览。后续真实桌面问答验收需要另行运行实验桌面并核验任务同步；不能以本次启动和 CLI fixture 结果替代。

## 仍需真实使用验收的边界

尚未关闭 API Desktop 自身的原生通知，也未证明异步问答、审批和所有桌面专有表单可被完整接管。原生问题与项目问题同步、精准返回真实桌面任务，仍需单独验收。共享 Windows 通知开关可能影响原版，不能作为 API 独占修复。

本轮日常控制器与两套 Codex 不重启、不覆盖，不修改日常启动器、认证、聊天或模型配置。隔离目录有自己的 `Rollback-ApiBridge.cmd` 和 `Start-WithoutBridge.cmd`；这两个入口只适用于本次隔离实验，不是日常环境回退工具。
