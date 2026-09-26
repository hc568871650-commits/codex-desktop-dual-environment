# 0.5 任务链接与实例归属

本机只读核验对象为 Store OpenAI.Codex 26.917.9434.0。未修改程序包、协议注册、真实配置或会话内容，也未向真实任务发起链接。

## 程序包证据

- Manifest仅注册一个codex协议，不能据此区分两套环境。
- app.asar内`.vite/build/src-DldfpmrL.js`约473378字节验证`codex://threads/<UUID>`；UUID为8-4-4-4-12十六进制格式。
- `bootstrap-CiIGnI3y.js`约575880字节解析threads链接，也接受可选hostId；约584739/615099字节按CODEX_ELECTRON_USER_DATA_PATH设置Electron userData，并通过Windows单实例锁及second-instance转交argv。
- `main-BR_2NHW6.js`约3580173字节在接收实例内执行thread/read，成功后才导航到任务。
- `webview/assets/app-initial-fc9a33fdda88.js`约10665952字节的原生完成提示取会话标题，缺失时回退首条用户消息/Turn complete；正文来自完成消息。控制器独立提示没有复制答案正文。

以上是该版本静态代码的定位记录，偏移随更新变化。没有将程序包中的字符串当作成功点击的运行证据。

## 控制器处理

1. 从已核验来源的完成事件保留instanceId、threadId、turnId；拒绝非UUID任务ID。
2. 由原启动链路启动或找到目标；继续核验PID、启动时间、程序路径、home和profile。
3. 程序路径必须等于当前发现的Store入口。读取目标进程的Electron目录仅允许返回指定路径变量，不返回密钥。
4. 有登记profile时，实际Electron目录必须存在且与登记路径一致；无profile的默认实例只接受未设置覆盖目录的目标。
5. 创建参数包含同一home、经过核验的Electron目录及规范化任务URI。不会用ShellExecute打开全局codex链接。
6. 第二次启动退出且目标身份保持不变，仅记为Requested；这不提供页面导航确认。入口未知则Unsupported，回退到对应端并展示说明。

标题读取兼容索引条目id/thread_name，从文件末尾有限读取；格式未知、锁定、丢失均使用默认标题。安装包JS未提供这一索引schema的稳定性承诺，故不把它作为导航归属依据。

## 验证与限制

导航专项用隔离PowerShell进程验证实际环境路径读取；允许发送的分支重定向到不存在的测试EXE，核对Windows参数解析，不启动真实Codex。编译宿主测试用GUI夹具验证卡片到API端的降级与原PID保留。未进行真实双实例的任务页面验收，未修复或替换Windows原生通知身份，也未为远程host拼接路由。
