# DoubaoVoiceBridge - macOS 豆包语音输入桥
SwiftPM + AppKit + Carbon + ApplicationServices

<directory>
Sources/ - 运行时代码 (2子目录: DoubaoVoiceBridge, DoubaoVoiceBridgeCore)
Tests/ - 核心行为回归测试 (1子目录: DoubaoVoiceBridgeCoreTests)
scripts/ - 打包、安装、状态检查与图标归一化脚本
support/ - macOS app bundle 元数据模板
</directory>

<config>
Package.swift - SwiftPM 包、target、product 与 macOS 版本下限
config.json - 用户配置模板，首次运行复制到 Application Support
README.md - 用户安装、配置、日志与打包说明
doubao-voice-bridge-app-spec.md - 行为规格与历史触发方案证据
</config>

架构决策:
DoubaoVoiceBridge 是编排层，只碰 macOS UI、事件 tap、焦点与进程生命周期。DoubaoVoiceBridgeCore 是纯策略与系统边界封装，承载配置、输入法、版本检测、权限报告和状态机。豆包 0.9.2 起使用免按模式，版本策略由 Core 统一判定，入口只消费策略结果。

开发规范:
TIS 输入法 API 只能沿主线程路径调用。触发逻辑先落测试，再改状态机或主流程。新增文件必须有 L3 头部；模块成员变化必须同步模块 codex.md。

变更日志:
2026-07-08 - 新增组合快捷键事件计划；支持右侧双修饰键语音快捷键，并将 app bundle 版本提升到 1.0.7。
2026-06-25 - 新增豆包输入法版本检测；0.9.2 及以后使用单次点按触发，旧版本保持预热后长按。
2026-06-25 - 将 app bundle 版本提升到 1.0.5，确保打包与安装验证能区分新触发策略。
