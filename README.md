# Windows Codex Desktop 双环境方案：官方订阅与 API Key Mode 一键切换

> 适合觉得 Codex Desktop 图形界面很好用，但官方订阅额度不够，又不想每天手动修改 API 路由、登录状态和配置文件的人。

## 方案摘要

在 Windows 上只安装一份 Codex Desktop，通过两个独立启动入口建立两套互不干扰的环境：

- **Codex 官方**：继续使用 ChatGPT Plus、Pro、Business 等官方订阅，保留原登录、项目和聊天记录。
- **Codex API**：使用自己的 API Key 和兼容 Responses API 的服务，拥有独立配置、项目列表、聊天记录和任务目录。

日常使用时不需要临时修改路由或反复登录，只需点击对应的桌面图标。

```text
同一份 Codex Desktop
│
├─ Codex 官方
│  └─ 官方账号、订阅额度、原项目与历史
│
└─ Codex API
   └─ API Key、独立配置、独立项目与历史
```

核心不是安装两个 Codex，而是同时隔离：

1. `CODEX_HOME`
2. Desktop/UI profile
3. 无项目任务目录
4. API 凭据

只隔离其中一部分，两个窗口仍可能混用项目列表、聊天历史或登录数据。

## 为什么需要双环境

Codex Desktop 的图形界面、项目管理、终端、文件操作和工具调用体验很好，但订阅额度与 API 额度是不同的使用方式。

常见做法是直接修改 `config.toml`，在官方路由和第三方 API 路由之间来回切换。这种方式有几个问题：

- 容易忘记当前正在消耗哪一套额度。
- 修改路由后通常需要重启应用。
- 项目列表和聊天历史仍混在一起。
- API 配置可能影响官方登录环境。
- 密钥容易被写进配置文件、脚本或命令历史。
- 切换次数多以后，很难判断问题来自账号、模型、缓存还是配置。

双环境方案把这些切换动作封装到两个固定入口中。用户看到图标就知道自己使用的是官方订阅还是 API，不需要理解每次启动背后的配置过程。

## 适合哪些人

- 已经在使用 Codex Desktop，不想改用纯命令行工具。
- 官方订阅额度不够，希望增加一套 API 额度。
- 需要经常在官方 Codex 和自定义 API 之间切换。
- 希望两边的项目、聊天和工作目录完全分开。
- 希望保留官方环境，不愿为了测试 API 覆盖原登录或历史。
- 希望应用更新后仍尽量共用同一份 Codex Desktop。

## 核心原理

### 1. 使用独立的 CODEX_HOME

`CODEX_HOME` 是 Codex 的主要数据目录，通常涉及用户配置、模型设置、会话状态和本地数据库。

API 环境应从一个全新的空目录开始，不能复制官方环境的 `auth.json`、SQLite 数据库、会话文件或历史记录。

```text
官方环境 → 原 CODEX_HOME
API 环境 → 独立 CODEX_HOME
```

这样可以避免 API 版读取官方账号的登录状态与任务历史。

### 2. 使用独立的 Desktop/UI profile

仅设置不同的 `CODEX_HOME` 还不够。

Codex Desktop 基于桌面应用运行时，还会保存窗口状态、项目列表、浏览器式缓存和其他 UI 数据。这部分可能位于单独的用户数据目录中。

API 入口启动时需要指定独立的 `--user-data-dir`：

```text
ChatGPT.exe --user-data-dir=<API 环境的独立 DesktopProfile>
```

这一步是防止两个窗口显示相同项目列表和界面状态的关键。

### 3. 分开无项目任务目录

在没有选择本地项目的情况下新建任务时，Codex Desktop 会自动创建一个工作目录。

两套环境应分别指定自己的无项目任务目录：

```toml
[desktop]
projectlessWorkspaceRoot = '<独立任务目录>'
```

否则即使登录和项目列表已经隔离，两边的新任务文件仍可能写到同一个默认目录。

### 4. 使用独立凭据

API 环境只应加载 API Key，不应拥有官方环境的认证文件。

建议：

- 不把 API Key 明文写入 `config.toml`。
- 不把密钥直接放进桌面快捷方式参数。
- 使用 Windows 本地加密能力保存密钥。
- 启动时临时注入 API 进程的环境变量。
- 启动完成后清理启动器自身环境中的密钥。
- 不在日志里记录完整请求头或凭据。

## 推荐目录结构

下面是一个不包含个人路径的通用结构：

```text
<API 环境根目录>
├─ CodexHome
├─ DesktopProfile
├─ Projectless
├─ Projects
├─ Credentials
├─ Launcher
├─ Backup
└─ Logs
```

作用分别是：

| 目录 | 用途 |
|---|---|
| `CodexHome` | API 版 Codex 配置、状态和会话数据 |
| `DesktopProfile` | API 版桌面 UI、项目列表与界面缓存 |
| `Projectless` | 没有选择项目时产生的任务文件 |
| `Projects` | API 版常用本地项目 |
| `Credentials` | 本地加密后的 API 凭据 |
| `Launcher` | 启动与密钥更新脚本 |
| `Backup` | 修改前的配置备份 |
| `Logs` | 不含密钥的启动日志 |

## API 配置示意

下面只展示结构，不包含任何真实服务商、地址或密钥：

```toml
model_provider = "custom-provider"
model = "<model-id>"
model_reasoning_effort = "medium"

[model_providers.custom-provider]
name = "Custom API"
base_url = "<API base URL>"
wire_api = "responses"
requires_openai_auth = false
env_key = "CUSTOM_API_KEY"

[desktop]
projectlessWorkspaceRoot = '<API 环境的独立任务目录>'
```

不同服务商的认证头、模型名称和接口兼容程度可能不同，应以实际文档为准。优先使用 API Key Mode；只有在当前 Codex Desktop 与服务商接口确实不兼容时，再考虑兼容模式。

## 启动器需要做什么

API 启动器的职责不是修改全局配置，而是在一个独立进程中准备环境：

1. 读取并解密 API Key。
2. 设置 API 版的 `CODEX_HOME`。
3. 确保各个独立目录存在。
4. 自动寻找当前安装的 Codex Desktop 程序。
5. 使用独立的 `--user-data-dir` 启动图形界面。
6. 清理启动器进程中的临时密钥。

概念流程如下：

```powershell
$env:CODEX_HOME = '<API CodexHome>'
$env:CUSTOM_API_KEY = '<从本地加密文件临时解密>'

Start-Process `
    -FilePath '<当前 Codex Desktop 程序>' `
    -ArgumentList '--user-data-dir=<API DesktopProfile>' `
    -WorkingDirectory '<API Projects>'

Remove-Item Env:\CUSTOM_API_KEY
```

公开分享的模板中不应包含真实密钥，也不建议使用明文示例误导使用者。

## 与 CC Switch 组合使用

这套双环境思路可以与 CC Switch 配合，但两者解决的问题不同：

- **双环境方案**负责隔离官方账号、API 环境、Desktop profile、项目历史和任务目录。
- **CC Switch**负责在指定的 Codex 配置目录中管理供应商、模型、API Key 和可选的本地协议转换。

推荐结构是：

```text
Codex 官方
└─ 保持原配置，不交给 CC Switch 改写

Codex API
├─ 独立 CODEX_HOME
├─ 独立 DesktopProfile
└─ CC Switch 只管理这套 CODEX_HOME
```

CC Switch 的设备设置中包含 `codexConfigDir`，应将它明确指向 API 环境的 `CodexHome`，不能指向官方环境，也不能继续使用默认的 `~/.codex`。CC Switch 的配置文件说明可参考其[官方仓库文档](https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/en/5-faq/5.1-config-files.md)。

如果希望 CC Switch 自身的供应商数据库、设置和备份也不留在系统盘，可以使用其可自定义的数据存储位置，将整套 CC Switch 数据放入 API 环境目录。

接入时需要注意：

1. **不要让 CC Switch 管理官方 CODEX_HOME。** 否则切换供应商时仍可能改写官方 `config.toml` 或认证状态，失去双环境的意义。
2. **API 环境不需要复制官方 `auth.json`。** CC Switch 的“切换第三方供应商时保留官方登录”功能适合希望在同一环境混用官方身份与第三方模型的人；本方案追求彻底隔离，因此不需要启用该模式。
3. **保留公共配置。** CC Switch 切换供应商时会写入活动 `config.toml`。首次接管后要检查无项目任务目录、上下文窗口、MCP、插件和权限设置是否仍被保留。
4. **原生 Responses API 通常不需要本地路由。** 如果供应商只支持 Chat Completions，才需要启用 CC Switch 的本地路由进行协议转换。
5. **切换后重启 API 版 Codex。** Codex 通常在启动时读取 `config.toml` 和模型目录；只重启 API 环境，不影响官方环境。
6. **分别验证配置与流量。** 既要检查 API Codex 的启动参数和任务目录，也要检查 CC Switch 当前供应商、路由日志以及供应商侧实际用量。

CC Switch 官方指南也说明，它会根据活动供应商改写 Codex 的 `config.toml`；对于原生支持 Responses API 的服务通常不需要本地协议转换，而修改模型映射后建议重启 Codex。具体行为可参考[CC Switch Codex 接入指南](https://github.com/SoftRent/cc-switch/blob/main/docs/guides/codex-official-auth-preservation-guide-en.md)。

因此，CC Switch 可以替代本文中“手工维护多个 API 供应商配置”的部分，但不能替代 Desktop profile 和任务目录隔离。最稳妥的组合是：**官方环境固定不动，API 环境保持独立，再让 CC Switch 只接管 API 环境。**

## 桌面入口

建议创建两个名称明显不同的快捷方式：

```text
Codex 官方
Codex API
```

- “Codex 官方”按原方式启动应用。
- “Codex API”调用专用启动器。

如果应用来自 Microsoft Store/MSIX，不建议把带版本号的安装路径永久写死。启动器可以在每次运行时查询当前安装位置，从而降低应用更新后快捷方式失效的概率。

## 已有任务目录如何迁移

不要在 Codex 正在运行时直接剪切整个无项目任务目录。旧聊天可能保存原始路径，运行中的数据库和任务文件也可能仍被占用。

比较稳妥的流程是：

1. 备份相关配置和状态文件。
2. 将旧任务目录完整复制到新磁盘。
3. 对比文件数量与总大小。
4. 关闭 Codex，进行最后一次增量同步。
5. 对源文件和目标文件计算哈希。
6. 校验通过后再删除旧位置的实体数据。
7. 如需兼容旧聊天，在原路径保留指向新目录的目录联接。

目录联接只负责兼容历史路径；实际文件可以全部存放在新磁盘。

## 必须做的隔离验证

两个窗口能同时打开，不代表隔离已经成功。至少应检查：

1. 官方环境仍能看到原有登录、项目和聊天。
2. API 环境首次启动时没有官方历史。
3. API 环境中不存在官方 `auth.json`。
4. 在 API 环境中新建项目或任务后，官方环境中不会出现。
5. 两个环境产生的无项目任务分别写入各自目录。
6. API 主进程的命令行包含独立的 `--user-data-dir`。
7. 两边分别发送一个小请求，确认消耗各自的额度。
8. 关闭其中一个环境时，不会结束另一个环境的主进程。

还可以使用固定推理题和复杂工具任务，测试模型质量、工具调用、错误恢复、首字延迟与缓存表现。

## 常见问题

### 为什么只改 CODEX_HOME 后，项目列表仍然混在一起？

因为 Desktop/UI profile 没有隔离。项目列表和窗口状态不一定全部保存在 `CODEX_HOME`。

### 为什么 API 配置已经改了，界面仍显示旧设置？

旧的 API 进程可能没有完全退出。配置修改时间晚于进程启动时间时，需要结束对应的 API 主进程，再从专用入口重新打开。

### 可以同时打开官方版和 API 版吗？

可以。前提是 API 版使用独立 Desktop profile，否则桌面应用可能把第二次启动合并到已有进程。

### 需要安装两份 Codex Desktop 吗？

通常不需要。共用程序、分离数据目录的维护成本更低。

### 应用更新后会失效吗？

如果启动器能够动态寻找当前安装的应用，一般只需复查配置兼容性。更新后建议重新验证进程参数、项目列表和任务写入位置。

### 开启长上下文会改变服务商计费吗？

客户端配置只决定 Codex 可使用的上下文预算，不会替服务商决定价格。官方 Codex、标准 API 和第三方中转可能采用不同计费规则，应查看实际账单。

### 能把整个环境上传到 GitHub 吗？

不建议。公开仓库只应包含脱敏文档、通用启动器模板、配置示例和 `.gitignore`，不能上传凭据、会话数据库、Desktop profile、任务文件、日志或备份。

## 安全与回滚

- 修改前备份官方配置。
- API 环境始终从空目录创建。
- 不覆盖、不复制官方认证文件。
- 为 API 环境保留独立备份目录。
- 启动器记录错误时不输出密钥。
- 删除 API 环境前先关闭对应进程。
- 回滚 API 环境不应要求修改官方安装。
- 目录迁移应在校验通过后才删除源文件。

## 实践结论

Windows 上的 Codex Desktop 可以通过“一份应用程序 + 两套数据环境”实现官方订阅与 API Key Mode 的长期共存。

真正可靠的双环境并不是简单切换 `base_url`，而是同时隔离 `CODEX_HOME`、Desktop profile、无项目任务目录和凭据。完成这些隔离后，复杂配置可以被封装在启动器中，用户日常只需要选择“Codex 官方”或“Codex API”。

对于喜欢 Codex Desktop，但受订阅额度限制、又不想反复修改路由的人，这是一种维护成本较低、可回滚、也比较接近日常桌面软件体验的方案。

---

检索关键词：`Codex Desktop API`、`Codex Desktop API Key Mode`、`Windows Codex 双开`、`Codex 双环境`、`CODEX_HOME`、`Codex user-data-dir`、`Codex 官方订阅和 API 切换`、`Codex 订阅额度不足`、`Codex Desktop 自定义 API`、`Codex 项目隔离`、`CC Switch Codex`、`CC Switch 双环境`。
