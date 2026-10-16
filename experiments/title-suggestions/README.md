# 标题建议：独立预览原型

> 2026-10-16 后续新增了 [原生接入模块](native/README.md)，并已安装到本机 API 启动链，等待完整重启后的 UI 验收。下面介绍的仍是可单独运行的网页预览，不要与原生模块的安装状态混淆。

此目录是阶段 B 的可运行原型，不是已安装的 Codex 插件。没有 CDP、窗口注入、SQLite 改写或真实聊天保存功能。`保存到此预览` 仅改变网页里的展示文字，刷新后恢复。代码原创，没有复制 Codex++ 源码。

## 先做无费用测试

需要 Python 3.11+，本机 `py -3` 已验证。双击 `Start-Mock.cmd`，将窗口显示的完整 `http://127.0.0.1:随机端口/#随机令牌` 地址复制到浏览器。页面应显示“模拟模式，不调用模型，不产生费用”。这个本地链接持有本次服务权限，不要分享；刷新后地址中的令牌已移除，需要从启动窗口重新打开完整链接。

服务在关闭命令窗口或按 Ctrl+C 后结束，不注册开机启动。仅监听 IPv4 回环地址，使用操作系统分配的端口，避免占用生产服务端口。默认模拟模式不读取任何 Codex Home/Profile、凭据或聊天记录。

1. 打开重命名预览，约 0.65 秒后应出现建议；原标题保持不变。
2. 点击“采用建议”，输入框才填入新标题；点击“取消”，页面当前标题不应改变。
3. 再次打开，内容未变时应显示“缓存”；点击“再想一个”，模拟模式应显示另一个标题。
4. 打开后马上在输入框输入文字，建议到达后点击“采用建议”，应保留你输入的文字并提示手动复制。
5. 打开后立即按 Esc，再次打开，前一次迟到结果不应覆盖新弹窗。
6. 修改模拟聊天标识或摘录，再打开，应生成新建议而不是使用另一聊天的缓存。
7. 清空摘录再打开，应提示 `empty_context`，仍能手动填写并保存到预览。
8. 选择建议并保存，只有网页里的“当前预览标题”改变；真实 Codex 标题完全不受影响。

## 真实 API 最小测试（显式启动才调用）

真实模式使用指定 Home 的 `config.toml` 中所选 Responses 供应商。不会悄悄切换官方账号、供应商或另一套 Home。`--model` 显式指定生成模型；未指定时沿用配置默认模型，可能费用更高。Desktop Profile 是本次预览的显式实例标签，只检查目录存在，不声称核验或控制运行中的 Desktop 进程。

推荐先使用页面自带的合成摘录。**打开预览、点击“再想一个”会调用真实供应商，可能计费；仅启动服务不会发往真实供应商。** 真实服务启动前会用临时 Home 和本地假 Responses 端点做一次零费用兼容探测；CLI 请求仍暴露工具或不能抓到请求就停止。

在 PowerShell 中使用明确路径，替换占位值：

```powershell
& '.\Start-Live.ps1' `
  -CodexHome 'X:\API实例\CodexHome' `
  -DesktopProfile 'X:\API实例\DesktopProfile' `
  -Cli 'X:\当前官方CLI\codex.exe' `
  -Model 'gpt-6-luna'
```

如果供应商配置用 `env_key`，需要从已有凭据环境启动。资源管理器启动通常没有该变量，此时服务会明确报 `credential_environment_missing`，不会尝试搜寻密钥。可显式提供现有 **Windows 当前用户 DPAPI SecureString 文本**文件：

```powershell
& '.\Start-Live.ps1' `
  -CodexHome 'X:\API实例\CodexHome' `
  -DesktopProfile 'X:\API实例\DesktopProfile' `
  -Cli 'X:\当前官方CLI\codex.exe' `
  -Model 'gpt-6-luna' `
  -CredentialFile 'X:\已有凭据\provider-key.dpapi' `
  -KeyEnvName 'PROVIDER_API_KEY'
```

包装脚本只在当前 PowerShell 进程及其 Python/CLI 子进程环境里临时提供密钥，退出时恢复原变量，不保存明文、不改用户/系统环境变量。参数里是路径与环境变量名，不是密钥。请使用专门的 PowerShell 窗口并正常 Ctrl+C 退出。

真实接口验证清单：模式显示 LIVE；打开后得到符合摘录的中文短标题；采用、编辑、取消都正常；错误时保留手动输入；重新打开命中缓存不应多次调用；供应商拒绝/不支持模型时不会换账号重试。原型对原生 Codex 弹窗、侧栏、标题持久化没有验收能力。

## 实现边界

- UI 每次 `open` 一次请求；关闭、切聊天、被新请求取代后按序号和 thread/request identity 丢弃迟到结果。只有点击“采用建议”才填入预览输入框；用户开始编辑后不会替换其文字。保存由宿主负责，此原型没有保存 API。
- 请求显式携带 threadId，但摘录由页面提供。服务没有历史扫描、任意文件读取、执行任意命令或聊天数据库接口。未来原生适配必须从已核验实例取得当前 threadId 与正文，不能把本预览当作身份验证层。
- 只保留最近最多 8,000 字符，每条最多 2,000 字符，只接受 user/assistant 文本；不带工具、图片、附件。空会话不调用模型。标题最大 60 字符，只接受严格 JSON 对象。
- 单并发、45 秒超时、取消后终止本次 CLI；有界摘录通过受控临时文件作为 stdin，避免子进程不读管道时阻塞；临时文件随调用清理；5 分钟内存缓存，最多 64 条，服务退出即清空；无自动后台轮询。
- CLI `exec --ephemeral --ignore-user-config --ignore-rules`，通过白名单重建所选 provider 的非敏感字段；原 Home 仅供 CLI 既有认证解析。禁用 shell、apps、plugins、hooks、memories、multi-agent、浏览器等，项目文档上限为 0，并使用精简标题指令。CLI 自身仍可能写常规运行缓存/日志；不保证原 Home 字节级不变。
- 静态 `http_headers` 在内存中转换为随机子进程环境变量，通过 `env_http_headers` 传递，值不进入命令行；已有 `env_http_headers` 验证环境变量存在且非空后保留。拒绝非法头名、CR/LF、控制字符、空值、重复头名。字面 bearer token、URL 查询参数、分层 profile 等未支持路由明确停止，不丢弃字段后假装沿用。只支持 Responses，非回环地址要求 HTTPS。
- 日志不回显 CLI 原始 stdout/stderr，因为供应商错误可能包含凭据或私人摘录。页面只收到固定错误码。HTTP 校验 Host、Origin、随机令牌、POST/JSON 与 48 KB 请求上限；无 CORS 跨站授权。
- 取消是尽力终止本地请求，不能保证上游已接收的调用不计费。关闭浏览器时 `/cancel` 可能未送达，服务仍在超时内结束。

## 开发验证

```powershell
py -3 -m unittest -v test_title_service.py
node test_suggestion.cjs
py -3 probe_cli.py --cli 'X:\当前官方CLI\codex.exe'
```

2026-10-16 本机结果：Python 11 项通过、纯 JS 控制器 7 场景通过。真实官方 CLI `9614f1d9b40d9c4f` 的离线 HTTP 抓包：`tools=[]`、1 次本地请求。精简后该合成请求的 JSON input 序列化约 22,206 字符，仍有 CLI 内建消息开销；这是字符测量，不是 Token 或账单。本轮未由本模块执行真实供应商调用；后续主任务如执行应单独记录。未自动操作 Codex 桌面 UI。

参考官方文档：[CLI 命令](https://learn.chatgpt.com/docs/developer-commands?surface=cli)、[配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)。配置开关按本机 CLI 离线请求验证，未来版本仍需重新跑 `probe_cli.py`。

## 原生接入前仍需完成

核验目标 Desktop 的 PID/创建时间、Home/Profile 和当前 host/threadId；在隔离客户端实现受控宿主通道；验证真实重命名弹窗里的建议、用户编辑保护、保存后的侧栏/标签同步及重启持久化。无可验证通道时保留独立预览，不直接改 SQLite 或猜测 DOM 补写。

回退：关闭服务即可；此目录没有修改启动器、控制器绑定、生产安装、开机项或真实标题。删除测试目录前确认服务已关闭。
