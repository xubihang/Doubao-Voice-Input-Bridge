# DoubaoVoiceBridgeCoreTests/
> L2 | 父级: /codex.md

成员清单
BridgeConfigTests.swift: 配置默认值、JSON 覆盖、快捷键解析、冲突归一化与用户配置落盘测试
BridgeStateMachineTests.swift: 状态机生命周期测试，覆盖等待、取消、长按释放、单点触发与输入法恢复
DoubaoImeVersionTests.swift: 豆包版本比较、bundle 版本读取与触发策略分流测试
HotkeyEventPlanTests.swift: 组合快捷键事件计划测试，锁定纯修饰键组合的逐步 flags 状态
LaunchAgentPlistTests.swift: LaunchAgent plist 生成结构测试
PermissionReportTests.swift: 权限报告、缺失项顺序与系统设置 URL 测试

模块法则:
测试锁定用户可感知行为，不测试 AppKit 事件 tap 细节。版本协议变化必须先在这里红灯，再进入 Core 实现。

[PROTOCOL]: 变更时更新此头部，然后检查 codex.md
