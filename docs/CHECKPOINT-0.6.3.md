# 0.6.3 检查点

当前目标：修复完全隐藏到后台时单击API慢。此前0.6.2只有最小化快路径，已部署到本机，但用户实际准备状态是窗口Visible=false且非Minimized。

已确认：两个根PID保持，API6848，普通最小化真实点击约700ms。隐藏路径重跑完整外部启动脚本。直接转交已验证Store exe/profile的探针81.5ms，root保留。

已改：Native抽出IsKnownProcess；Instances.RequestNativeInstanceActivation在已运行状态直接原生转交，cold StartOrFind外部启动保留；ControllerWork optional KnownInstances指纹+快身份校验；Panel传cache且消费QuickIdentity结果后快focus。版本0.6.3。Test-HiddenActivation实际单实例隐藏夹具8项通过。

已验证：7个受影响套件通过，日志test-results/activation-validation-20260926-222605；本机受控隐藏恢复旧路径2608.8ms，新路径305.2ms，原API PID均6848且前台成功，不含625ms。待办：打包升级校验、安装本机（已有持续授权），真实隐藏后的已安装入口验收并给用户测试。

不要重启/关闭两套Codex进程，不读取/解密密钥，不使用ShowWindow强显hidden主窗/浮窗。临时脚本在test-results内，公开包排除。真实tray工具诊断尝试包含未能可靠命中overflow图标的失败，不能把所有超时都当作产品根因。
