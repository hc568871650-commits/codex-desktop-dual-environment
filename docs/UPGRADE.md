# 从 0.1 升级到 0.2

无需重新输入密钥，也不搬动原来的 Codex 数据。升级只在工具目录内进行，默认读取 `%LOCALAPPDATA%\CodexDualLauncher\settings.json`，这是 0.1 启动器的设置位置。

## 推荐：使用升级包

1. 将 `CodexDualLauncher-0.1-to-0.2.0-upgrade.zip` 解压到一个新文件夹。
2. 关闭旧版启动器/控制器窗口。**官方和 API Codex 可以继续运行，不需要退出。**
3. 双击新文件夹里的 **Upgrade.cmd**，选择旧工具文件夹：里面应当有 `Start.cmd` 和 `src`。不要选择官方 home 或 API 数据目录。
4. 升级完成后双击旧目录的 **Start.cmd**，打开 0.2 面板。

这条路径先检查、备份旧工具文件，再替换；任何被更新的工具文件都记入 `upgrades\<时间与随机ID>\upgrade.local.json`。源升级包不用留在原位置，旧工具目录仍是固定运行目录。

## 也支持：直接覆盖解压

1. 关闭旧启动器/控制器；两套 Codex 保持运行。
2. 将 **0.2 完整包**解压到旧工具文件夹，同名工具文件选择替换。
3. 双击 **Start.cmd**。首次运行会读取原 0.1 设置、生成本机实例配置及任务栏控制程序，以后启动复用它们。

完整包不包含 `settings.json`、`instances.local.json`、认证、密钥或用户数据，所以不会通过压缩包同名文件覆盖这些内容。

**回滚区别：直接解压覆盖发生在升级脚本之前，脚本无法备份已经被解压替换的 0.1 程序文件。** 希望完整恢复旧版时，使用推荐升级包，或在解压前保留旧工具文件夹副本。这里的“支持覆盖”不表示可以覆盖正在运行的 EXE；先退出控制器。

## 保留哪些内容

- 原 API home、Desktop profile、项目、无项目任务目录与 DPAPI 密钥位置继续使用，不复制认证文件，不读取或解密密钥。
- 官方 home 和默认 profile 保持。能解析原无项目目录时记录实际值；未显式设置或无法解析时使用 `projectlessMode: inherit`，继续由原官方配置决定，不猜测路径、不改写官方 TOML。这种情况下不宣称已验证其物理任务目录隔离。
- 0.2 已存在的 `instances.local.json` 原样保留，稳定实例 ID 不变。
- 用户额外放入工具目录的文件不删除。升级失败时自动尝试恢复工具文件，数据目录不进入升级事务。
- 已有指向 `Start.cmd` 的快捷方式仍可用；0.2 的任务栏 EXE 路径保持。直接指向旧 `src\Launcher.ps1` 的自建快捷方式不自动改写，请改用 `Start.cmd` 或新 EXE。

重复升级没有变化时返回 `AlreadyCurrent`，不重新生成密钥、配置或 UUID。

## 自定义设置位置

若 0.1 用过自定义 `-SettingsPath`，可运行：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File scripts\Upgrade.ps1 `
  -TargetDirectory 'C:\Tools\CodexDual' `
  -LegacySettingsPath 'C:\Settings\codex-launcher.json'
```

加 `-CheckOnly` 只检查不写入。缺少旧设置、API 标记、必要文件或路径冲突时明确停止，不重新初始化你的环境。CC Switch/自建启动器等非 0.1 托管环境，继续用已有环境注册流程，不自动迁移凭据。

## 回滚

关闭控制器，在 0.2 工具或升级包中双击 **Rollback.cmd**，选择此次升级的 `upgrades\...` 备份文件夹。也可用 `scripts\Rollback-Upgrade.ps1 -Snapshot <备份路径>`。

回滚前会核对升级后文件和备份哈希。工具或控制配置已经被用户改动时停止，避免覆盖新修改。新增用户项目目录即使为空也不自动删除。回滚记录和备份保留；原 0.1 设置、凭据与用户数据始终保留。

如果自动恢复遇到文件锁、磁盘或权限问题，记录会标注 `RollbackIncomplete`，不会宣称已回滚成功。保留备份并先排除阻塞原因，不要清空数据目录。
