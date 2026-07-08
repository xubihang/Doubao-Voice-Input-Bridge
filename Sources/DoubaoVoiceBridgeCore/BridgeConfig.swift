/**
 * [INPUT]: 依赖 Foundation 的 JSONDecoder/Data
 * [OUTPUT]: 对外提供 BridgeKey、BridgeHotkey、BridgeConfig、PartialBridgeConfig 类型与 JSON 加载/默认配置模板，保证触发键与语音键不复用同一物理键
 * [POS]: DoubaoVoiceBridgeCore 的配置层，被 main.swift 入口消费；定义所有可调时序参数、快捷键解析与配置不变量
 * [PROTOCOL]: 变更时更新此头部，然后检查 codex.md
 */
import Foundation

public enum BridgeKey: Equatable, Hashable, Sendable {
    case leftShift
    case rightShift
    case shift
    case leftControl
    case rightControl
    case control
    case leftOption
    case rightOption
    case option
    case leftCommand
    case rightCommand
    case command
    case tab
    case space
    case character(String)

    public var isModifier: Bool {
        switch self {
        case .leftShift, .rightShift, .shift,
             .leftControl, .rightControl, .control,
             .leftOption, .rightOption, .option,
             .leftCommand, .rightCommand, .command:
            return true
        case .tab, .space, .character:
            return false
        }
    }

    func overlaps(_ other: BridgeKey) -> Bool {
        semanticKeys.contains { other.semanticKeys.contains($0) }
    }

    private var semanticKeys: Set<String> {
        switch self {
        case .leftShift:
            return ["leftShift"]
        case .rightShift:
            return ["rightShift"]
        case .shift:
            return ["leftShift", "rightShift"]
        case .leftControl:
            return ["leftControl"]
        case .rightControl:
            return ["rightControl"]
        case .control:
            return ["leftControl", "rightControl"]
        case .leftOption:
            return ["leftOption"]
        case .rightOption:
            return ["rightOption"]
        case .option:
            return ["leftOption", "rightOption"]
        case .leftCommand:
            return ["leftCommand"]
        case .rightCommand:
            return ["rightCommand"]
        case .command:
            return ["leftCommand", "rightCommand"]
        case .tab:
            return ["tab"]
        case .space:
            return ["space"]
        case .character(let value):
            return ["character:\(value)"]
        }
    }
}

public struct BridgeHotkey: Equatable, Sendable {
    public var keys: [BridgeKey]

    public init(keys: [BridgeKey]) {
        self.keys = keys
    }

    public func contains(_ key: BridgeKey) -> Bool {
        keys.contains(key)
    }

    public func overlaps(_ other: BridgeHotkey) -> Bool {
        keys.contains { key in
            other.keys.contains { key.overlaps($0) }
        }
    }

    public static func parse(_ value: String) -> BridgeHotkey? {
        let keys = value
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map(parseKey)

        guard !keys.isEmpty, keys.allSatisfy({ $0 != nil }) else {
            return nil
        }
        return BridgeHotkey(keys: keys.compactMap { $0 })
    }

    private static func parseKey(_ value: String) -> BridgeKey? {
        let normalized = value
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()

        switch normalized {
        case "leftshift", "lshift":
            return .leftShift
        case "rightshift", "rshift":
            return .rightShift
        case "shift":
            return .shift
        case "leftcontrol", "lcontrol", "leftctrl", "lctrl":
            return .leftControl
        case "rightcontrol", "rcontrol", "rightctrl", "rctrl":
            return .rightControl
        case "control", "ctrl":
            return .control
        case "leftoption", "loption", "leftalt", "lalt":
            return .leftOption
        case "rightoption", "roption", "rightalt", "ralt":
            return .rightOption
        case "option", "alt":
            return .option
        case "leftcommand", "lcommand", "leftcmd", "lcmd":
            return .leftCommand
        case "rightcommand", "rcommand", "rightcmd", "rcmd":
            return .rightCommand
        case "command", "cmd":
            return .command
        case "tab":
            return .tab
        case "space":
            return .space
        default:
            return parseCharacterKey(value)
        }
    }

    private static func parseCharacterKey(_ value: String) -> BridgeKey? {
        let lowercased = value.lowercased()
        guard lowercased.count == 1, let scalar = lowercased.unicodeScalars.first else {
            return nil
        }

        let accepted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789`-=[]\\;',./")
        guard accepted.contains(scalar) else {
            return nil
        }
        return .character(lowercased)
    }
}

public struct BridgeConfig: Equatable, Sendable {
    public var launchAtLogin: Bool
    public var restoreDelay: TimeInterval
    public var postSwitchSettleDelay: TimeInterval
    public var switchWaitTimeout: TimeInterval
    public var switchPollInterval: TimeInterval
    public var focusBounceBackDelay: TimeInterval
    public var focusBounceSettleDelay: TimeInterval
    public var triggerHoldDelay: TimeInterval
    public var optionWarmupTapDuration: TimeInterval
    public var optionWarmupToHoldDelay: TimeInterval
    public var tapDuration: TimeInterval
    public var triggerHotkey: BridgeHotkey
    public var voiceHotkey: BridgeHotkey

    public static let `default` = BridgeConfig(
        launchAtLogin: false,
        restoreDelay: 0.20,
        postSwitchSettleDelay: 0.50,
        switchWaitTimeout: 2.00,
        switchPollInterval: 0.05,
        focusBounceBackDelay: 0.16,
        focusBounceSettleDelay: 0.16,
        triggerHoldDelay: 0.25,
        optionWarmupTapDuration: 0.05,
        optionWarmupToHoldDelay: 0.22,
        tapDuration: 0.15,
        triggerHotkey: BridgeHotkey(keys: [.rightCommand]),
        voiceHotkey: BridgeHotkey(keys: [.leftOption])
    )

    public static func load(from data: Data) throws -> BridgeConfig {
        let partial = try JSONDecoder().decode(PartialBridgeConfig.self, from: data)
        var config = BridgeConfig.default
        config.launchAtLogin = partial.launchAtLogin ?? config.launchAtLogin
        config.restoreDelay = partial.restoreDelay ?? config.restoreDelay
        config.postSwitchSettleDelay = partial.postSwitchSettleDelay ?? config.postSwitchSettleDelay
        config.switchWaitTimeout = partial.switchWaitTimeout ?? config.switchWaitTimeout
        config.switchPollInterval = partial.switchPollInterval ?? config.switchPollInterval
        config.focusBounceBackDelay = partial.focusBounceBackDelay ?? config.focusBounceBackDelay
        config.focusBounceSettleDelay = partial.focusBounceSettleDelay ?? config.focusBounceSettleDelay
        config.triggerHoldDelay = partial.triggerHoldDelay ?? config.triggerHoldDelay
        config.optionWarmupTapDuration = partial.optionWarmupTapDuration ?? config.optionWarmupTapDuration
        config.optionWarmupToHoldDelay = partial.optionWarmupToHoldDelay ?? config.optionWarmupToHoldDelay
        config.tapDuration = partial.tapDuration ?? config.tapDuration
        config.triggerHotkey = partial.triggerHotkey.flatMap(BridgeHotkey.parse) ?? config.triggerHotkey
        config.voiceHotkey = partial.voiceHotkey.flatMap(BridgeHotkey.parse) ?? config.voiceHotkey
        if config.voiceHotkey.overlaps(config.triggerHotkey) {
            config.voiceHotkey = BridgeConfig.default.voiceHotkey
        }
        return config
    }

    public static func loadFromDefaultLocation() -> BridgeConfig {
        loadFromDefaultLocation(
            userConfigURL: defaultUserConfigURL,
            templateURLs: candidateTemplateConfigURLs()
        )
    }

    public static func loadFromDefaultLocation(
        userConfigURL: URL,
        templateURLs: [URL],
        fileManager: FileManager = .default
    ) -> BridgeConfig {
        ensureUserConfigExists(
            at: userConfigURL,
            templateURLs: templateURLs,
            fileManager: fileManager
        )

        guard let data = try? Data(contentsOf: userConfigURL) else {
            return .default
        }
        return (try? load(from: data)) ?? .default
    }

    public static var defaultUserConfigURL: URL {
        let applicationSupportURL = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupportURL
            .appendingPathComponent("DoubaoVoiceBridge", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private static func candidateTemplateConfigURLs() -> [URL] {
        var urls: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent("config.json"))
        }

        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("config.json"))

        return urls
    }

    private static func ensureUserConfigExists(
        at url: URL,
        templateURLs: [URL],
        fileManager: FileManager
    ) {
        guard !fileManager.fileExists(atPath: url.path) else {
            return
        }

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = firstValidTemplateData(from: templateURLs) ?? defaultConfigData
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    private static func firstValidTemplateData(from urls: [URL]) -> Data? {
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  (try? load(from: data)) != nil else {
                continue
            }
            return data
        }
        return nil
    }

    private static var defaultConfigData: Data {
        """
        {
          "launchAtLogin": false,
          "restoreDelay": 0.2,
          "postSwitchSettleDelay": 0.5,
          "switchWaitTimeout": 2.0,
          "switchPollInterval": 0.05,
          "focusBounceBackDelay": 0.16,
          "focusBounceSettleDelay": 0.16,
          "triggerHoldDelay": 0.25,
          "optionWarmupTapDuration": 0.05,
          "optionWarmupToHoldDelay": 0.22,
          "tapDuration": 0.15,
          "triggerHotkey": "RightCommand",
          "voiceHotkey": "LeftOption"
        }
        """.data(using: .utf8)!
    }
}

private struct PartialBridgeConfig: Decodable {
    var launchAtLogin: Bool?
    var restoreDelay: TimeInterval?
    var postSwitchSettleDelay: TimeInterval?
    var switchWaitTimeout: TimeInterval?
    var switchPollInterval: TimeInterval?
    var focusBounceBackDelay: TimeInterval?
    var focusBounceSettleDelay: TimeInterval?
    var triggerHoldDelay: TimeInterval?
    var optionWarmupTapDuration: TimeInterval?
    var optionWarmupToHoldDelay: TimeInterval?
    var tapDuration: TimeInterval?
    var triggerHotkey: String?
    var voiceHotkey: String?
}
