/**
 * [INPUT]: 依赖 XCTest、DoubaoVoiceBridgeCore 的 BridgeHotkey/BridgeKey/HotkeyEventPlan
 * [OUTPUT]: 对外提供组合快捷键事件序列测试，锁定 modifier down/up 的 activeModifiers 状态
 * [POS]: DoubaoVoiceBridgeCoreTests 的按键计划测试文件，约束入口层 HotkeySender 的纯策略输入
 * [PROTOCOL]: 变更时更新此头部，然后检查 codex.md
 */
import XCTest
@testable import DoubaoVoiceBridgeCore

final class HotkeyEventPlanTests: XCTestCase {
    func testPureModifierComboTapKeepsRealModifierStateAtEveryStep() {
        let hotkey = BridgeHotkey(keys: [.rightCommand, .rightShift])

        let steps = HotkeyEventPlan.tapSteps(for: hotkey)

        XCTAssertEqual(steps, [
            HotkeyEventStep(key: .rightCommand, isDown: true, activeModifiers: [.rightCommand]),
            HotkeyEventStep(key: .rightShift, isDown: true, activeModifiers: [.rightCommand, .rightShift]),
            HotkeyEventStep(key: .rightShift, isDown: false, activeModifiers: [.rightCommand]),
            HotkeyEventStep(key: .rightCommand, isDown: false, activeModifiers: [])
        ])
    }

    func testRightSideModifierFlagsIncludeGenericAndSideSpecificBits() {
        let rawFlags = HotkeyEventPlan.flagsRawValue(forModifiers: [.rightCommand, .rightShift])

        XCTAssertEqual(rawFlags, 0x100000 | 0x20000 | 0x10 | 0x4)
    }
}
