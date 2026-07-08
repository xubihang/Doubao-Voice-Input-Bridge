# DoubaoVoiceBridgeCore/
> L2 | 父级: /codex.md

成员清单
AppLogger.swift: 应用日志写入器，串行队列写入 ~/Library/Logs/DoubaoVoiceBridge/app.log
BridgeConfig.swift: 配置模型与 JSON 加载器，解析快捷键、时序参数（含 tapDuration）、默认配置模板，并阻断触发键与语音键复用同一物理键
BridgeStateMachine.swift: 语音会话状态机，统一触发按下、阈值、长按、单点、释放与恢复动作
DoubaoImeVersionDetector.swift: 豆包输入法版本探测器与触发策略判定，0.9.2 起切到 tapHotkey
HotkeyEventPlan.swift: 组合快捷键事件计划器，生成真实按下/释放顺序与每步 activeModifiers
InputSourceController.swift: Carbon TIS 输入法控制器，选择、读取、等待当前输入源
LaunchAgentPlist.swift: 用户级 LaunchAgent plist 生成器，绑定 app 可执行文件与日志目录
PermissionReport.swift: 权限报告模型，描述 Accessibility 与 Input Monitoring 状态

模块法则:
Core 只表达可测试的策略、配置与系统边界，不直接拥有 AppKit 菜单栏生命周期。所有版本差异先收敛为 DoubaoImeVoiceStrategy，再由入口执行实际按键事件。

[PROTOCOL]: 变更时更新此头部，然后检查 codex.md
