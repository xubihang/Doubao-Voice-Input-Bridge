/**
 * [INPUT]: 依赖 XCTest、DoubaoVoiceBridgeCore 的 BridgeConfig/BridgeHotkey/BridgeKey
 * [OUTPUT]: 对外提供 BridgeConfig 默认值、JSON 解析、快捷键解析、tapDuration 向后兼容等测试用例
 * [POS]: DoubaoVoiceBridgeCoreTests 的配置测试文件，覆盖 BridgeConfig 的所有加载路径
 * [PROTOCOL]: 变更时更新此头部，然后检查 codex.md
 */
import XCTest
@testable import DoubaoVoiceBridgeCore

final class BridgeConfigTests: XCTestCase {
    func testDefaultConfigMatchesProjectTimingSpec() {
        let config = BridgeConfig.default

        let configurableFields = Set(Mirror(reflecting: config).children.compactMap(\.label))
        XCTAssertFalse(configurableFields.contains("targetInputMethod"))
        XCTAssertFalse(configurableFields.contains("userInputMethod"))
        XCTAssertFalse(config.launchAtLogin)
        XCTAssertEqual(config.restoreDelay, 0.20)
        XCTAssertEqual(config.postSwitchSettleDelay, 0.50)
        XCTAssertEqual(config.switchWaitTimeout, 2.00)
        XCTAssertEqual(config.focusBounceBackDelay, 0.16)
        XCTAssertEqual(config.focusBounceSettleDelay, 0.16)
        XCTAssertEqual(config.triggerHoldDelay, 0.25)
        XCTAssertEqual(config.optionWarmupTapDuration, 0.05)
        XCTAssertEqual(config.optionWarmupToHoldDelay, 0.22)
        XCTAssertEqual(config.tapDuration, 0.15)
        XCTAssertEqual(config.triggerHotkey, BridgeHotkey(keys: [.rightCommand]))
        XCTAssertEqual(config.voiceHotkey, BridgeHotkey(keys: [.leftOption]))
    }

    func testPartialJSONConfigKeepsDefaultsForMissingValues() throws {
        let data = """
        {
          "launchAtLogin": false,
          "restoreDelay": 0.35
        }
        """.data(using: .utf8)!

        let config = try BridgeConfig.load(from: data)

        XCTAssertFalse(config.launchAtLogin)
        XCTAssertEqual(config.restoreDelay, 0.35)
        XCTAssertEqual(config.postSwitchSettleDelay, 0.50)
        XCTAssertEqual(config.triggerHoldDelay, 0.25)
        XCTAssertEqual(config.triggerHotkey, BridgeHotkey(keys: [.rightCommand]))
    }

    func testJSONConfigParsesPlusSeparatedHotkeys() throws {
        let data = """
        {
          "triggerHotkey": "RightCommand+Space",
          "voiceHotkey": "LeftOption+Tab"
        }
        """.data(using: .utf8)!

        let config = try BridgeConfig.load(from: data)

        XCTAssertEqual(config.triggerHotkey, BridgeHotkey(keys: [.rightCommand, .space]))
        XCTAssertEqual(config.voiceHotkey, BridgeHotkey(keys: [.leftOption, .tab]))
    }

    func testJSONConfigRejectsShiftedCharacterHotkeyTokens() throws {
        let data = """
        {
          "triggerHotkey": "RightCommand+!",
          "voiceHotkey": "LeftOption"
        }
        """.data(using: .utf8)!

        let config = try BridgeConfig.load(from: data)

        XCTAssertEqual(config.triggerHotkey, BridgeHotkey(keys: [.rightCommand]))
        XCTAssertEqual(config.voiceHotkey, BridgeHotkey(keys: [.leftOption]))
    }

    func testHotkeyMembershipDistinguishesTriggerKeyFromVoiceKey() {
        let trigger = BridgeHotkey(keys: [.rightCommand])
        let voice = BridgeHotkey(keys: [.leftOption])

        XCTAssertTrue(trigger.contains(.rightCommand))
        XCTAssertFalse(trigger.contains(.leftOption))
        XCTAssertTrue(voice.contains(.leftOption))
    }

    func testDefaultLocationCreatesUserConfigFromProjectTemplateWhenMissing() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let userConfigURL = tempDirectory
            .appendingPathComponent("Application Support/DoubaoVoiceBridge/config.json")
        let templateURL = tempDirectory.appendingPathComponent("template-config.json")
        try """
        {
          "launchAtLogin": false,
          "restoreDelay": 0.45
        }
        """.data(using: .utf8)!.write(to: templateURL)

        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let config = BridgeConfig.loadFromDefaultLocation(
            userConfigURL: userConfigURL,
            templateURLs: [templateURL]
        )

        XCTAssertEqual(config.restoreDelay, 0.45)
        XCTAssertTrue(fileManager.fileExists(atPath: userConfigURL.path))
    }

    func testDefaultLocationPrefersExistingUserConfigOverTemplate() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let userConfigURL = tempDirectory
            .appendingPathComponent("Application Support/DoubaoVoiceBridge/config.json")
        let templateURL = tempDirectory.appendingPathComponent("template-config.json")
        try fileManager.createDirectory(
            at: userConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "restoreDelay": 0.31
        }
        """.data(using: .utf8)!.write(to: userConfigURL)
        try """
        {
          "restoreDelay": 0.90
        }
        """.data(using: .utf8)!.write(to: templateURL)

        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let config = BridgeConfig.loadFromDefaultLocation(
            userConfigURL: userConfigURL,
            templateURLs: [templateURL]
        )

        XCTAssertEqual(config.restoreDelay, 0.31)
    }

    func testDefaultLocationWritesBuiltInConfigWhenNoTemplateExists() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let userConfigURL = tempDirectory
            .appendingPathComponent("Application Support/DoubaoVoiceBridge/config.json")

        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let config = BridgeConfig.loadFromDefaultLocation(
            userConfigURL: userConfigURL,
            templateURLs: []
        )

        XCTAssertFalse(config.launchAtLogin)
        XCTAssertEqual(config.restoreDelay, BridgeConfig.default.restoreDelay)
        XCTAssertTrue(fileManager.fileExists(atPath: userConfigURL.path))
    }

    func testTapDurationFallsBackToDefaultWhenMissing() throws {
        let data = """
        {
          "restoreDelay": 0.35
        }
        """.data(using: .utf8)!

        let config = try BridgeConfig.load(from: data)

        XCTAssertEqual(config.tapDuration, 0.15)
    }

    func testTapDurationOverriddenFromJSON() throws {
        let data = """
        {
          "tapDuration": 0.1
        }
        """.data(using: .utf8)!

        let config = try BridgeConfig.load(from: data)

        XCTAssertEqual(config.tapDuration, 0.1)
    }
}
