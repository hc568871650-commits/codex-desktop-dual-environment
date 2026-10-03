# 0.8.8 配图来源

2026-10-03 从当前源码重新生成，共 8 张 PNG。均为真实 WinForms 控件渲染，使用独立示例配置与题目；不使用日常实例、真实凭据、会话历史或真实 API 请求。图片不是 AI 生成的界面概念稿。

| 文件 | 内容 |
|---|---|
| overview-dark.png | 深色双环境概览，示例模型 example-model |
| settings-light.png | 浅色偏好设置 |
| notifications-light.png | API 通知控制台 |
| completion-dark.png / completion-light.png | 深浅两套紧凑完成卡片 |
| question-dark.png / question-light.png | 深浅两套多题作答窗，滚动可见其余内容；示例选项不发送 |
| quick-notifications-dark.png | 精简后的通知快捷页 |

在仓库根目录重建：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File scripts\Export-DocumentationImages.ps1
```

脚本读取 version.json 决定默认输出目录，只将运行数据写入 test-results/docs-images-*。概览与设置使用控制器 SmokeTest 模式，其启动边界被替换为记录操作；不会启动或关闭 Codex。卡片与问题来自正式控件，截图使用 DrawToBitmap。脚本退出时释放测试窗口，生成图像哈希证据到测试目录。

文档图片用于说明布局，不作为问答端到端、系统通知、进程运行状态或真实模型调用验收证据。0.8.8 发布候选已核对 8 张图片随 docs 一起进入完整包和升级包，当前指南中的图片相对链接可达；最终包与提交一致性由发布核验记录确认。
