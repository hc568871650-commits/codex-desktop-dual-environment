# 0.6.3 · 后台隐藏窗口的原生唤起

用户准备了实际慢场景后，读取到两个Codex根进程仍运行，API的主窗口visible=false、minimized=false。0.6.2只优化了普通最小化，未覆盖这种完全隐藏的情况。

隐藏路径原来会重新执行外部PowerShell启动器，重复查找安装包、加载模块和准备启动环境。0.6.3对已运行且身份重新核验通过的实例，使用同一Store可执行文件、同一CODEX_HOME及profile直接发送原生单实例唤起请求；不读取或解密凭据，不重跑外部启动脚本。原进程必须保持身份不变，secondary必须退出，才视为转交成功。

缓存从UI传给后台时包含实例ID/home/profile及配置exe指纹；逐项匹配并实时核验进程完整身份后才省去全量发现。后台结果回到UI再次实时核验再聚焦。真正未启动时继续原外部启动器冷启动流程。

不直接强显隐藏HWND，不操作内部工具/浮窗；没有新增全局协议或跨实例猜测。625ms默认单双击判定保持。

## 实测与证据范围

- 0.6.2的普通最小化真实鼠标测试为689–705ms（含625ms）；不代表隐藏窗口已优化。
- 用户提供的隐藏状态：API PID6848、主窗口5445548、visible=false、minimized=false。读取状态未拉起窗口。
- 原生direct转交探针81.5ms退出，原PID保留并有可见窗口；该数据是探针转交耗时，不是完整托盘点击耗时。
- 受控隐藏同一已核验主窗口后，旧0.6.2路径2608.8ms、新worker路径305.2ms，均恢复前台且原PID保留。这是两次单次流程测量，不含625ms，不是用户手工点击统计。
- 7个受影响回归套件通过；隐藏单实例专项8项通过。最终本机验收见dist/HANDOFF-0.6.3.md。

技术参考：Electron的单实例转交/second-instance事件，https://www.electronjs.org/docs/latest/api/app#apprequestsingleinstancelockadditionaldata 。实际支持以本机身份、secondary退出和窗口核验结果为准。
