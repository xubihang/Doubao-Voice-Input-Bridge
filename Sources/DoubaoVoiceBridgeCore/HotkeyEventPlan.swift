/**
 * [INPUT]: 依赖 BridgeHotkey/BridgeKey 的快捷键结构
 * [OUTPUT]: 对外提供 HotkeyEventStep、HotkeyEventPlan，生成真实按下/释放顺序、每步 activeModifiers 与修饰键 raw flags
 * [POS]: DoubaoVoiceBridgeCore 的按键事件计划层，被入口 HotkeySender 消费，避免组合修饰键 flags 状态失真
 * [PROTOCOL]: 变更时更新此头部，然后检查 codex.md
 */
import Foundation

public struct HotkeyEventStep: Equatable, Sendable {
    public var key: BridgeKey
    public var isDown: Bool
    public var activeModifiers: [BridgeKey]

    public init(key: BridgeKey, isDown: Bool, activeModifiers: [BridgeKey]) {
        self.key = key
        self.isDown = isDown
        self.activeModifiers = activeModifiers
    }
}

public enum HotkeyEventPlan {
    public static func pressSteps(for hotkey: BridgeHotkey) -> [HotkeyEventStep] {
        var activeModifiers: [BridgeKey] = []
        return orderedKeys(for: hotkey).map { key in
            if key.isModifier {
                activeModifiers.append(key)
            }
            return HotkeyEventStep(key: key, isDown: true, activeModifiers: activeModifiers)
        }
    }

    public static func releaseSteps(for hotkey: BridgeHotkey) -> [HotkeyEventStep] {
        var activeModifiers = hotkey.keys.filter(\.isModifier)
        return orderedKeys(for: hotkey).reversed().map { key in
            if key.isModifier {
                activeModifiers.removeAll { $0 == key }
            }
            return HotkeyEventStep(key: key, isDown: false, activeModifiers: activeModifiers)
        }
    }

    public static func tapSteps(for hotkey: BridgeHotkey) -> [HotkeyEventStep] {
        pressSteps(for: hotkey) + releaseSteps(for: hotkey)
    }

    public static func flagsRawValue(forModifiers modifiers: [BridgeKey]) -> UInt64 {
        modifiers.reduce(0) { rawValue, key in
            rawValue | modifierFlagsRawValue(for: key)
        }
    }

    private static func orderedKeys(for hotkey: BridgeHotkey) -> [BridgeKey] {
        hotkey.keys.filter(\.isModifier) + hotkey.keys.filter { !$0.isModifier }
    }

    private static func modifierFlagsRawValue(for key: BridgeKey) -> UInt64 {
        switch key {
        case .leftShift:
            return 0x20000 | 0x2
        case .rightShift:
            return 0x20000 | 0x4
        case .shift:
            return 0x20000
        case .leftControl:
            return 0x40000 | 0x1
        case .rightControl:
            return 0x40000 | 0x2000
        case .control:
            return 0x40000
        case .leftOption:
            return 0x80000 | 0x20
        case .rightOption:
            return 0x80000 | 0x40
        case .option:
            return 0x80000
        case .leftCommand:
            return 0x100000 | 0x8
        case .rightCommand:
            return 0x100000 | 0x10
        case .command:
            return 0x100000
        case .tab, .space, .character:
            return 0
        }
    }
}
