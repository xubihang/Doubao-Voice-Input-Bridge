/**
 * [INPUT]: 依赖 AppKit/ApplicationServices/Carbon 的菜单栏、权限、事件 tap 与焦点控制能力，依赖 DoubaoVoiceBridgeCore 的配置、状态机、输入法与版本策略
 * [OUTPUT]: 对外提供 DoubaoVoiceBridge 菜单栏进程入口和本地按住说话桥接流程
 * [POS]: Sources/DoubaoVoiceBridge 的唯一可执行入口，编排权限、LaunchAgent、输入法切换、豆包语音触发与恢复
 * [PROTOCOL]: 变更时更新此头部，然后检查 codex.md
 */
import AppKit
import ApplicationServices
import Carbon
import DoubaoVoiceBridgeCore

private let doubaoInputMethodName = "豆包输入法"
private let launchAgentLabel = "local.doubao-voice-bridge.keepalive"
private let keyboardEventMask = (1 << CGEventType.flagsChanged.rawValue)
    | (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.keyUp.rawValue)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = BridgeConfig.loadFromDefaultLocation()
    private let logger = AppLogger()
    private let inputSources = InputSourceController()
    private let doubaoVersionDetector = DoubaoImeVersionDetector()
    private var voiceStrategy: DoubaoImeVoiceStrategy = .holdHotkey
    private var voiceHotkeySender: HotkeySender
    private let focusBouncer = FocusBouncer()
    private lazy var launchAgent = LaunchAgentManager(label: launchAgentLabel, logger: logger)
    private var statusItem: NSStatusItem?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var enabled = true
    private var triggerHotkeyDown = false
    private var triggerHoldPending = false
    private var triggerHoldPendingID = UUID()
    private var voiceHotkeyIsDown = false
    private var activeKeyCodes = Set<Int64>()
    private var permissionWindowController: PermissionWindowController?
    private var didCompleteStartupAfterPermissions = false
    private var sessionID = UUID()
    private var machine = BridgeStateMachine()
    private var inputMethodToRestore: String?

    override init() {
        voiceHotkeySender = HotkeySender(hotkey: config.voiceHotkey)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        refreshDoubaoVoiceStrategy(reason: "startup")
        gateStartupOnPermissions()
        logger.log("app launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if voiceHotkeyIsDown {
            voiceHotkeySender.up()
        }
        restorePreviousInputMethod()
        disableEventTap()
        logger.log("app terminated")
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "豆"

        let menu = NSMenu()
        let enableItem = NSMenuItem(title: "Disable Key Capture", action: #selector(toggleEnabled), keyEquivalent: "")
        enableItem.target = self
        menu.addItem(enableItem)

        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        let configItem = NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        let reloadConfigItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfigFromMenu), keyEquivalent: "")
        reloadConfigItem.target = self
        menu.addItem(reloadConfigItem)

        let permissionItem = NSMenuItem(title: "Check Permissions", action: #selector(checkPermissionsFromMenu), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit and Disable Auto Restart", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        enabled.toggle()
        sender.title = enabled ? "Disable Key Capture" : "Enable Key Capture"
        statusItem?.button?.title = enabled ? "豆" : "豆-"
        logger.log(enabled ? "key capture enabled" : "key capture disabled")
        if !enabled {
            releaseOptionIfNeeded()
            restorePreviousInputMethod()
            triggerHotkeyDown = false
            triggerHoldPending = false
            triggerHoldPendingID = UUID()
            activeKeyCodes.removeAll()
            sessionID = UUID()
            machine.handle(.reset)
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(AppLogger.defaultLogURL)
    }

    @objc private func openConfig() {
        _ = BridgeConfig.loadFromDefaultLocation()
        NSWorkspace.shared.activateFileViewerSelecting([BridgeConfig.defaultUserConfigURL])
    }

    @objc private func reloadConfigFromMenu() {
        releaseOptionIfNeeded()
        restorePreviousInputMethod()
        triggerHotkeyDown = false
        triggerHoldPending = false
        triggerHoldPendingID = UUID()
        activeKeyCodes.removeAll()
        sessionID = UUID()
        machine.handle(.reset)

        config = BridgeConfig.loadFromDefaultLocation()
        voiceHotkeySender = HotkeySender(hotkey: config.voiceHotkey)
        refreshDoubaoVoiceStrategy(reason: "config reload")
        logger.log(
            "config reloaded: triggerHotkey=\(hotkeyDescription(config.triggerHotkey)) voiceHotkey=\(hotkeyDescription(config.voiceHotkey)) triggerHoldDelay=\(config.triggerHoldDelay) postSwitchSettleDelay=\(config.postSwitchSettleDelay)"
        )
    }

    private func installLaunchAgentIfNeeded() {
        do {
            let shouldRelaunchUnderAgent = try launchAgent.installForCurrentApp()
            if shouldRelaunchUnderAgent {
                logger.log("launch agent installed; terminating manual instance")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            }
        } catch {
            logger.log("failed to install launch agent: \(error)")
        }
    }

    @objc private func checkPermissionsFromMenu() {
        let report = permissionReport()
        if report.isReady {
            showPermissionsReadyAlert()
        } else {
            showPermissionWindow(isStartupGate: false)
        }
    }

    @objc private func quit() {
        do {
            try launchAgent.uninstall()
            logger.log("launch agent disabled by quit")
        } catch {
            logger.log("failed to disable launch agent during quit: \(error)")
        }
        NSApp.terminate(nil)
    }

    private func permissionReport() -> PermissionReport {
        return PermissionReport(
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: inputMonitoringPermissionIsGranted()
        )
    }

    private func inputMonitoringPermissionIsGranted() -> Bool {
        guard #available(macOS 10.15, *) else {
            return true
        }
        guard CGPreflightListenEventAccess() else {
            return false
        }

        let mask = keyboardEventMask
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: permissionProbeEventTapCallback,
            userInfo: nil
        ) else {
            return false
        }
        CFMachPortInvalidate(tap)
        return true
    }

    private func gateStartupOnPermissions() {
        let report = permissionReport()
        if report.isReady {
            logger.log("permissions ready")
            completeStartupAfterPermissions()
            return
        }

        let missingNames = report.missingPermissions.map(\.displayName).joined(separator: ", ")
        logger.log("permissions missing: \(missingNames)")
        showPermissionWindow(isStartupGate: true)
    }

    private func completeStartupAfterPermissions() {
        guard !didCompleteStartupAfterPermissions else {
            return
        }
        let report = permissionReport()
        guard report.isReady else {
            let missingNames = report.missingPermissions.map(\.displayName).joined(separator: ", ")
            logger.log("startup blocked by missing permissions: \(missingNames)")
            showPermissionWindow(isStartupGate: true)
            return
        }
        didCompleteStartupAfterPermissions = true
        installLaunchAgentIfNeeded()
        installEventTap()
    }

    private func showPermissionWindow(isStartupGate: Bool) {
        NSApp.setActivationPolicy(.regular)
        if let controller = permissionWindowController {
            controller.isStartupGate = controller.isStartupGate || isStartupGate
            controller.showWindow(nil)
            controller.bringToFront()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let controller = PermissionWindowController(
            isStartupGate: isStartupGate,
            reportProvider: { [weak self] in
                self?.permissionReport()
                    ?? PermissionReport(accessibilityGranted: false, inputMonitoringGranted: false)
            },
            onReady: { [weak self] in
                guard let self else { return }
                self.permissionWindowController = nil
                NSApp.setActivationPolicy(.accessory)
                self.completeStartupAfterPermissions()
            },
            onClose: { [weak self] report, wasStartupGate in
                guard let self else { return }
                self.permissionWindowController = nil
                if wasStartupGate, !report.isReady {
                    self.uninstallLaunchAgent(reason: "permission gate closed with missing permissions")
                }
                NSApp.terminate(nil)
            }
        )
        permissionWindowController = controller
        controller.showWindow(nil)
        controller.bringToFront()
    }

    private func uninstallLaunchAgent(reason: String) {
        do {
            try launchAgent.uninstall()
            logger.log("\(reason); launch agent disabled")
        } catch {
            logger.log("\(reason); failed to disable launch agent: \(error)")
        }
    }

    private func showPermissionsReadyAlert() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "DoubaoVoiceBridge permissions are ready"
        alert.informativeText = "\(hotkeyDescription(config.triggerHotkey)) can now be used as push-to-talk."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func installEventTap() {
        let mask = keyboardEventMask
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            logger.log("failed to create event tap; grant Input Monitoring and Accessibility")
            showPermissionWindow(isStartupGate: false)
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.log("event tap installed")
    }

    private func disableEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    fileprivate func handleKeyboardEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        guard enabled else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown {
            activeKeyCodes.insert(keyCode)
        } else if type == .keyUp {
            activeKeyCodes.remove(keyCode)
        }

        let isTriggerEvent = isTriggerEvent(keyCode: keyCode)
        if type == .keyDown, !isTriggerEvent, triggerHoldPending {
            cancelPendingTriggerHold(reason: "non-trigger key pressed before hold threshold")
        }
        guard isTriggerEvent else {
            return Unmanaged.passUnretained(event)
        }

        let isDown = hotkeyIsDown(config.triggerHotkey, event: event)
        logger.log(
            "trigger hotkey event: physicalDown=\(isDown) internalDown=\(triggerHotkeyDown) keyCode=\(keyCode) rawFlags=0x\(String(event.flags.rawValue, radix: 16))"
        )
        if isDown, !triggerHotkeyDown {
            triggerHotkeyDown = true
            handleTriggerHotkeyDown()
        } else if !isDown, triggerHotkeyDown {
            triggerHotkeyDown = false
            handleTriggerHotkeyUp()
        }

        return shouldSwallowTriggerEvent() ? nil : Unmanaged.passUnretained(event)
    }

    private func handleTriggerHotkeyDown() {
        logger.log("trigger hotkey down")
        let actions = machine.handle(.rightCommandDown)
        if actions.contains(.startVoiceSession) {
            startVoiceSession()
        }
        triggerHoldPending = true
        triggerHoldPendingID = UUID()
        let pendingID = triggerHoldPendingID
        DispatchQueue.main.asyncAfter(deadline: .now() + config.triggerHoldDelay) { [weak self] in
            self?.completePendingTriggerHoldIfCurrent(pendingID)
        }
    }

    private func handleTriggerHotkeyUp() {
        logger.log("trigger hotkey up")
        triggerHoldPending = false
        triggerHoldPendingID = UUID()
        let actions = machine.handle(.rightCommandUp)
        if actions.contains(.cancelPendingOptionHold) {
            sessionID = UUID()
            logger.log("cancel pending voice hotkey hold")
        }
        if actions.contains(.releaseOptionHold) {
            releaseOptionIfNeeded()
        }
        if actions.contains(.restorePreviousInputMethod) {
            DispatchQueue.main.asyncAfter(deadline: .now() + config.restoreDelay) { [weak self] in
                self?.restorePreviousInputMethod()
            }
        }
    }

    private func completePendingTriggerHoldIfCurrent(_ pendingID: UUID) {
        guard triggerHoldPending, triggerHoldPendingID == pendingID, triggerHotkeyDown else {
            return
        }
        triggerHoldPending = false
        logger.log("trigger hold threshold passed")
        let actions = machine.handle(.triggerHoldThresholdPassed)
        if actions.contains(.startVoiceSession) {
            startVoiceSession()
        }
    }

    private func cancelPendingTriggerHold(reason: String) {
        triggerHoldPending = false
        triggerHoldPendingID = UUID()
        sessionID = UUID()
        machine.handle(.reset)
        logger.log("cancel pending trigger hold: \(reason)")
    }

    private func refreshDoubaoVoiceStrategy(reason: String) {
        let version = doubaoVersionDetector.installedVersionString()
        voiceStrategy = DoubaoImeVoiceStrategy.resolve(versionString: version)
        logger.log(
            "doubao ime strategy refreshed: reason=\(reason) version=\(version ?? "unknown") strategy=\(voiceStrategy.logName)"
        )
    }

    private func hotkeyIsDown(_ hotkey: BridgeHotkey, event: CGEvent) -> Bool {
        hotkey.keys.allSatisfy { key in
            if key.isModifier {
                return modifierIsDown(key, flags: event.flags)
            }
            return keyCodes(for: key).contains { activeKeyCodes.contains(Int64($0)) }
        }
    }

    private func isTriggerEvent(keyCode: Int64) -> Bool {
        config.triggerHotkey.keys.contains { key in
            keyCodes(for: key).contains { Int64($0) == keyCode }
        }
    }

    private func shouldSwallowTriggerEvent() -> Bool {
        !config.triggerHotkey.keys.allSatisfy(\.isModifier)
    }

    private func startVoiceSession() {
        sessionID = UUID()
        let currentSession = sessionID
        let originalApp = NSWorkspace.shared.frontmostApplication
        let originalWindow = FocusBouncer.focusedWindow(for: originalApp)
        let currentInput = inputSources.currentInputSourceName()
        inputMethodToRestore = currentInput
        logger.log("record original input source: \(currentInput)")
        logger.log("switch to doubao input source: \(doubaoInputMethodName)")

        // TIS APIs (selectInputSource, TISCreateInputSourceList) must be called
        // from the main thread. macOS 15+ enforces this via dispatch assertion.
        _ = inputSources.selectInputSource(namedOrIdentifiedBy: doubaoInputMethodName)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            Thread.sleep(forTimeInterval: self.config.postSwitchSettleDelay)
            let confirmed = self.inputSources.waitUntilActive(
                matches: doubaoInputMethodName,
                timeout: self.config.switchWaitTimeout,
                pollInterval: self.config.switchPollInterval
            )
            self.logger.log(confirmed ? "confirmed doubao input source" : "doubao input source confirmation timed out")

            DispatchQueue.main.async {
                guard self.sessionID == currentSession, self.triggerHotkeyDown else { return }
                self.logger.log("start app focus bounce")
                self.focusBouncer.bounce(
                    originalApp: originalApp,
                    originalWindow: originalWindow,
                    backDelay: self.config.focusBounceBackDelay,
                    settleDelay: self.config.focusBounceSettleDelay
                ) { [weak self] in
                    self?.startVoiceTriggerIfCurrent(currentSession)
                }
            }
        }
    }

    private func startVoiceTriggerIfCurrent(_ currentSession: UUID) {
        switch voiceStrategy {
        case .holdHotkey:
            startOptionWarmupIfCurrent(currentSession)
        case .tapHotkey:
            tapVoiceHotkeyIfCurrent(currentSession)
        }
    }

    private func startOptionWarmupIfCurrent(_ currentSession: UUID) {
        guard sessionID == currentSession, triggerHotkeyDown else {
            return
        }
        logger.log("voice hotkey warmup tap")
        voiceHotkeySender.tap(duration: config.tapDuration) { [weak self] in
            guard let self, self.sessionID == currentSession else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.config.optionWarmupToHoldDelay) { [weak self] in
                guard let self, self.sessionID == currentSession, self.triggerHotkeyDown else { return }
                self.logger.log("voice hotkey formal hold down")
                self.voiceHotkeySender.down()
                self.voiceHotkeyIsDown = true
                self.machine.handle(.optionHoldStarted)
            }
        }
    }

    private func tapVoiceHotkeyIfCurrent(_ currentSession: UUID) {
        guard sessionID == currentSession, triggerHotkeyDown else {
            logger.log("tapVoiceHotkeyIfCurrent skipped: session mismatch or trigger not down")
            return
        }
        logger.log("voice hotkey single tap for doubao免按模式, duration=\(config.tapDuration)")
        voiceHotkeySender.tap(duration: config.tapDuration) { [weak self] in
            guard let self, self.sessionID == currentSession else { return }
            self.logger.log("tap completion callback, sending tapVoiceTriggerSent")
            self.machine.handle(.tapVoiceTriggerSent)
        }
    }

    private func releaseOptionIfNeeded() {
        guard voiceHotkeyIsDown else {
            return
        }
        voiceHotkeySender.up()
        voiceHotkeyIsDown = false
        logger.log("voice hotkey release")
    }

    private func restorePreviousInputMethod() {
        guard let inputMethod = inputMethodToRestore else {
            logger.log("skip input method restore: no previous input source recorded")
            return
        }
        inputMethodToRestore = nil
        logger.log("restore previous input method: \(inputMethod)")
        _ = inputSources.selectInputSource(namedOrIdentifiedBy: inputMethod)
    }
}

@main
enum DoubaoVoiceBridgeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        _ = delegate
    }
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard [.flagsChanged, .keyDown, .keyUp].contains(type), let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    return app.handleKeyboardEvent(event, type: type)
}

private let permissionProbeEventTapCallback: CGEventTapCallBack = { _, _, event, _ in
    Unmanaged.passUnretained(event)
}

private let leftShiftMask: UInt64 = 0x2
private let rightShiftMask: UInt64 = 0x4
private let leftControlMask: UInt64 = 0x1
private let rightControlMask: UInt64 = 0x2000
private let leftOptionMask: UInt64 = 0x20
private let rightOptionMask: UInt64 = 0x40
private let leftCommandMask: UInt64 = 0x8
private let rightCommandMask: UInt64 = 0x10

private extension DoubaoImeVoiceStrategy {
    var logName: String {
        switch self {
        case .holdHotkey:
            return "holdHotkey"
        case .tapHotkey:
            return "tapHotkey"
        }
    }
}

private func modifierIsDown(_ key: BridgeKey, flags: CGEventFlags) -> Bool {
    switch key {
    case .leftShift:
        return (flags.rawValue & leftShiftMask) != 0
    case .rightShift:
        return (flags.rawValue & rightShiftMask) != 0
    case .shift:
        return flags.contains(.maskShift)
    case .leftControl:
        return (flags.rawValue & leftControlMask) != 0
    case .rightControl:
        return (flags.rawValue & rightControlMask) != 0
    case .control:
        return flags.contains(.maskControl)
    case .leftOption:
        return (flags.rawValue & leftOptionMask) != 0
    case .rightOption:
        return (flags.rawValue & rightOptionMask) != 0
    case .option:
        return flags.contains(.maskAlternate)
    case .leftCommand:
        return (flags.rawValue & leftCommandMask) != 0
    case .rightCommand:
        return (flags.rawValue & rightCommandMask) != 0
    case .command:
        return flags.contains(.maskCommand)
    case .tab, .space, .character:
        return false
    }
}

private func flags(for hotkey: BridgeHotkey) -> CGEventFlags {
    hotkey.keys.reduce(CGEventFlags()) { flags, key in
        var flags = flags
        switch key {
        case .leftShift, .rightShift, .shift:
            flags.insert(.maskShift)
        case .leftControl, .rightControl, .control:
            flags.insert(.maskControl)
        case .leftOption, .rightOption, .option:
            flags.insert(.maskAlternate)
        case .leftCommand, .rightCommand, .command:
            flags.insert(.maskCommand)
        case .tab, .space, .character:
            break
        }
        return flags
    }
}

private func keyCode(for key: BridgeKey) -> CGKeyCode? {
    keyCodes(for: key).first
}

private func keyCodes(for key: BridgeKey) -> [CGKeyCode] {
    switch key {
    case .leftShift:
        return [56]
    case .rightShift:
        return [60]
    case .shift:
        return [56, 60]
    case .leftControl:
        return [59]
    case .rightControl:
        return [62]
    case .control:
        return [59, 62]
    case .leftOption:
        return [58]
    case .rightOption:
        return [61]
    case .option:
        return [58, 61]
    case .leftCommand:
        return [55]
    case .rightCommand:
        return [54]
    case .command:
        return [55, 54]
    case .tab:
        return [48]
    case .space:
        return [49]
    case .character(let character):
        return characterKeyCodes[character].map { [$0] } ?? []
    }
}

private let characterKeyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
    "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, "`": 50
]

private func hotkeyDescription(_ hotkey: BridgeHotkey) -> String {
    hotkey.keys.map { key in
        switch key {
        case .leftShift: return "LeftShift"
        case .rightShift: return "RightShift"
        case .shift: return "Shift"
        case .leftControl: return "LeftControl"
        case .rightControl: return "RightControl"
        case .control: return "Control"
        case .leftOption: return "LeftOption"
        case .rightOption: return "RightOption"
        case .option: return "Option"
        case .leftCommand: return "LeftCommand"
        case .rightCommand: return "RightCommand"
        case .command: return "Command"
        case .tab: return "Tab"
        case .space: return "Space"
        case .character(let character): return character
        }
    }.joined(separator: "+")
}

private final class PermissionWindowController: NSWindowController, NSWindowDelegate {
    var isStartupGate: Bool

    private let reportProvider: () -> PermissionReport
    private let onReady: () -> Void
    private let onClose: (PermissionReport, Bool) -> Void
    private var timer: Timer?
    private var latestReport: PermissionReport
    private var didCloseFromEnable = false
    private var shouldRecoverFocusFromSettings = false

    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let inputMonitoringStatus = NSTextField(labelWithString: "")
    private let accessibilityAction = CallbackButton(title: "Allow")
    private let inputMonitoringAction = CallbackButton(title: "Allow")
    private let enableButton = NSButton(title: "Enable Bridge", target: nil, action: nil)

    init(
        isStartupGate: Bool,
        reportProvider: @escaping () -> PermissionReport,
        onReady: @escaping () -> Void,
        onClose: @escaping (PermissionReport, Bool) -> Void
    ) {
        self.isStartupGate = isStartupGate
        self.reportProvider = reportProvider
        self.onReady = onReady
        self.onClose = onClose
        self.latestReport = reportProvider()

        let contentView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        contentView.material = .hudWindow
        contentView.blendingMode = .behindWindow
        contentView.state = .active
        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DoubaoVoiceBridge Permissions"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = contentView

        super.init(window: window)
        window.delegate = self
        buildContent(in: contentView)
        refresh()
        startPolling()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        guard !didCloseFromEnable else {
            return
        }
        onClose(latestReport, isStartupGate)
    }

    private func buildContent(in contentView: NSView) {
        let appIcon = PermissionHeroIconView()
        appIcon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Enable Doubao Voice Bridge")
        title.font = .systemFont(ofSize: 30, weight: .bold)
        title.alignment = .center
        title.lineBreakMode = .byWordWrapping

        let message = NSTextField(wrappingLabelWithString: "Doubao Voice Bridge needs these permissions to listen for the trigger hotkey and return focus after voice input. They are only used while the bridge is running.")
        message.font = .systemFont(ofSize: 16)
        message.textColor = .secondaryLabelColor
        message.alignment = .center

        let accessibilityRow = permissionRow(
            title: "Accessibility",
            detail: "Allows Doubao Voice Bridge to restore the app you were using after switching input.",
            statusLabel: accessibilityStatus,
            actionButton: accessibilityAction,
            symbolName: "accessibility",
            accentColor: .systemBlue
        ) { [weak self] in
            NSWorkspace.shared.open(PermissionKind.accessibility.settingsURL)
            self?.markSettingsOpened()
            self?.refresh()
        }

        let inputMonitoringRow = permissionRow(
            title: "Input Monitoring",
            detail: "Allows the bridge to detect your configured push-to-talk trigger.",
            statusLabel: inputMonitoringStatus,
            actionButton: inputMonitoringAction,
            symbolName: "keyboard",
            accentColor: .systemTeal
        ) { [weak self] in
            NSWorkspace.shared.open(PermissionKind.inputMonitoring.settingsURL)
            self?.markSettingsOpened()
            self?.refresh()
        }

        enableButton.target = self
        enableButton.action = #selector(enableBridge)
        enableButton.bezelStyle = .rounded
        enableButton.keyEquivalent = "\r"
        enableButton.controlSize = .large

        let footer = NSTextField(labelWithString: "This window checks permission status automatically.")
        footer.font = .systemFont(ofSize: 12)
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .center

        let buttonRow = NSView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addSubview(enableButton)
        enableButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [appIcon, title, message, accessibilityRow, inputMonitoringRow, footer, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 68),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -68),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 88),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -34),
            appIcon.widthAnchor.constraint(equalToConstant: 92),
            appIcon.heightAnchor.constraint(equalToConstant: 92),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.86),
            accessibilityRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputMonitoringRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            enableButton.centerXAnchor.constraint(equalTo: buttonRow.centerXAnchor),
            enableButton.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),
            enableButton.widthAnchor.constraint(equalToConstant: 150),
            buttonRow.heightAnchor.constraint(equalToConstant: 34)
        ])

        stack.setCustomSpacing(22, after: message)
        stack.setCustomSpacing(14, after: accessibilityRow)
        stack.setCustomSpacing(20, after: inputMonitoringRow)
        stack.setCustomSpacing(8, after: footer)
    }

    private func permissionRow(
        title: String,
        detail: String,
        statusLabel: NSTextField,
        actionButton: CallbackButton,
        symbolName: String,
        accentColor: NSColor,
        action: @escaping () -> Void
    ) -> NSView {
        let icon = PermissionSymbolView(symbolName: symbolName, accentColor: accentColor)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 14)

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.alignment = .right

        let openButton = actionButton
        openButton.callback = action
        openButton.bezelStyle = .rounded
        openButton.controlSize = .large

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5

        let trailingStack = NSStackView(views: [statusLabel, openButton])
        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 14

        let row = NSStackView(views: [icon, textStack, trailingStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        row.translatesAutoresizingMaskIntoConstraints = false

        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingStack.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            statusLabel.widthAnchor.constraint(equalToConstant: 74),
            openButton.widthAnchor.constraint(equalToConstant: 92)
        ])

        let card = PermissionCardView(contentView: row)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 92)
        ])
        return card
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            self.recoverFocusIfSettingsClosed()
        }
    }

    private func refresh() {
        latestReport = reportProvider()
        updateStatus(
            label: accessibilityStatus,
            isGranted: latestReport.accessibilityGranted
        )
        updateStatus(
            label: inputMonitoringStatus,
            isGranted: latestReport.inputMonitoringGranted
        )
        enableButton.isHidden = !latestReport.isReady
        enableButton.isEnabled = latestReport.isReady
    }

    private func markSettingsOpened() {
        shouldRecoverFocusFromSettings = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.recoverFocusIfSettingsClosed()
        }
    }

    private func recoverFocusIfSettingsClosed() {
        guard shouldRecoverFocusFromSettings else {
            return
        }
        let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if bundleIdentifier == "com.apple.SystemSettings" || bundleIdentifier == "com.apple.systempreferences" {
            return
        }
        shouldRecoverFocusFromSettings = false
        bringToFront()
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func updateStatus(label: NSTextField, isGranted: Bool) {
        label.stringValue = "Done ✓"
        label.textColor = .labelColor
        label.isHidden = !isGranted

        let button = label === accessibilityStatus ? accessibilityAction : inputMonitoringAction
        button.title = "Allow"
        button.isHidden = isGranted
    }

    @objc private func enableBridge() {
        refresh()
        guard latestReport.isReady else {
            return
        }
        didCloseFromEnable = true
        timer?.invalidate()
        close()
        onReady()
    }
}

private final class PermissionHeroIconView: NSView {
    private let appIcon: NSImage? = {
        if let image = NSImage(named: "AppIcon") {
            return image
        }
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) {
            return image
        }
        return nil
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 14
        layer?.shadowOffset = NSSize(width: 0, height: 8)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let appIcon else {
            return
        }

        appIcon.draw(
            in: bounds.insetBy(dx: 2, dy: 2),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

private final class PermissionSymbolView: NSView {
    private let symbolName: String
    private let accentColor: NSColor

    init(symbolName: String, accentColor: NSColor) {
        self.symbolName = symbolName
        self.accentColor = accentColor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image.isTemplate = true
            accentColor.set()
            image.draw(
                in: bounds.insetBy(dx: 14, dy: 14),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
    }
}

private final class PermissionCardView: NSView {
    init(contentView: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 24
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 14
        layer?.shadowOffset = NSSize(width: 0, height: 5)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            contentView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class CallbackButton: NSButton {
    var callback: () -> Void

    init(title: String, action: @escaping () -> Void = {}) {
        self.callback = action
        super.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(runCallback)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runCallback() {
        callback()
    }
}

private final class HotkeySender {
    private let hotkey: BridgeHotkey
    private let source = CGEventSource(stateID: .hidSystemState)

    init(hotkey: BridgeHotkey) {
        self.hotkey = hotkey
    }

    // MARK: - 长按: down 保持, up 释放

    func down() {
        for key in hotkey.keys where key.isModifier {
            postModifier(key: key, down: true)
        }
        for key in hotkey.keys where !key.isModifier {
            postKey(key: key, down: true)
        }
    }

    func up() {
        for key in hotkey.keys.reversed() where !key.isModifier {
            postKey(key: key, down: false)
        }
        for key in hotkey.keys.reversed() where key.isModifier {
            postModifier(key: key, down: false)
        }
    }

    // MARK: - 单次点按: 完整事件序列 (flagsChanged + keyDown -> keyUp + flagsChanged)

    func tap(duration: TimeInterval, completion: (() -> Void)? = nil) {
        NSLog("[HotkeySender] tap started: duration=%.3f", duration)
        for key in hotkey.keys where key.isModifier {
            postModifier(key: key, down: true)
        }
        for key in hotkey.keys where !key.isModifier {
            postKey(key: key, down: true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            NSLog("[HotkeySender] tap releasing keys")
            for key in self.hotkey.keys.reversed() where !key.isModifier {
                self.postKey(key: key, down: false)
            }
            for key in self.hotkey.keys.reversed() where key.isModifier {
                self.postModifier(key: key, down: false)
            }
            NSLog("[HotkeySender] tap completed")
            completion?()
        }
    }

    // MARK: - 修饰键事件 (flagsChanged + keyDown/keyUp)

    private func postModifier(key: BridgeKey, down: Bool) {
        guard let keyCode = keyCode(for: key) else { return }

        // 修饰键的 keyDown/keyUp 会自动触发 flagsChanged
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
        event?.flags = down ? flags(for: hotkey) : remainingFlags(excluding: key)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - 普通键事件 (仅 keyDown/keyUp)

    private func postKey(key: BridgeKey, down: Bool) {
        guard let keyCode = keyCode(for: key) else { return }
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
        event?.flags = flags(for: hotkey)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Flags 计算

    /// keyUp 时 flags 反映"除刚释放键外的其余修饰键"
    private func remainingFlags(excluding excludedKey: BridgeKey) -> CGEventFlags {
        hotkey.keys
            .filter { $0.isModifier && $0 != excludedKey }
            .reduce(CGEventFlags()) { result, key in
                var result = result
                switch key {
                case .leftShift, .rightShift, .shift:
                    result.insert(.maskShift)
                case .leftControl, .rightControl, .control:
                    result.insert(.maskControl)
                case .leftOption, .rightOption, .option:
                    result.insert(.maskAlternate)
                case .leftCommand, .rightCommand, .command:
                    result.insert(.maskCommand)
                case .tab, .space, .character:
                    break
                }
                return result
            }
    }
}

private final class FocusBouncer {
    func bounce(
        originalApp: NSRunningApplication?,
        originalWindow: AXUIElement?,
        backDelay: TimeInterval,
        settleDelay: TimeInterval,
        completion: @escaping () -> Void
    ) {
        activateNeutralApp(excluding: originalApp)
        DispatchQueue.main.asyncAfter(deadline: .now() + backDelay) {
            originalApp?.activate(options: [.activateIgnoringOtherApps])
            if let originalWindow {
                AXUIElementSetAttributeValue(originalWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(originalWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: completion)
        }
    }

    static func focusedWindow(for app: NSRunningApplication?) -> AXUIElement? {
        guard let pid = app?.processIdentifier else {
            return nil
        }
        let element = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func activateNeutralApp(excluding originalApp: NSRunningApplication?) {
        if originalApp?.bundleIdentifier != Bundle.main.bundleIdentifier {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            return
        }

        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            finder.activate(options: [.activateIgnoringOtherApps])
            return
        }

        if let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            NSWorkspace.shared.openApplication(at: finderURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

private final class LaunchAgentManager {
    private let label: String
    private let logger: AppLogger
    private let fileManager: FileManager

    init(label: String, logger: AppLogger, fileManager: FileManager = .default) {
        self.label = label
        self.logger = logger
        self.fileManager = fileManager
    }

    func installForCurrentApp() throws -> Bool {
        guard let executableURL = Bundle.main.executableURL else {
            throw LaunchAgentError.missingExecutableURL
        }

        let plistURL = Self.plistURL(label: label)
        let logDirectoryURL = AppLogger.defaultLogURL.deletingLastPathComponent()
        let plist = LaunchAgentPlist(
            label: label,
            executableURL: executableURL,
            logDirectoryURL: logDirectoryURL
        )
        let data = try plist.data()

        try fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        let existingData = try? Data(contentsOf: plistURL)
        let plistChanged = existingData != data
        if plistChanged {
            try data.write(to: plistURL, options: .atomic)
            logger.log("launch agent plist written: \(plistURL.path)")
        }

        let runningUnderLaunchAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
        let isLoaded = launchctlPrint()

        if isLoaded, plistChanged, !runningUnderLaunchAgent {
            _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())/\(label)"])
        }

        if !isLoaded || (plistChanged && !runningUnderLaunchAgent) {
            try runLaunchctlOrThrow(arguments: ["bootstrap", "gui/\(getuid())", plistURL.path])
            try runLaunchctlOrThrow(arguments: ["enable", "gui/\(getuid())/\(label)"])
            logger.log("launch agent bootstrapped")
            return !runningUnderLaunchAgent
        }

        try runLaunchctlOrThrow(arguments: ["enable", "gui/\(getuid())/\(label)"])
        logger.log("launch agent already active")
        return !runningUnderLaunchAgent
    }

    func uninstall() throws {
        let plistURL = Self.plistURL(label: label)
        if fileManager.fileExists(atPath: plistURL.path) {
            try fileManager.removeItem(at: plistURL)
        }
        if launchctlPrint() {
            _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())/\(label)"])
        }
    }

    var isInstalled: Bool {
        let plistURL = Self.plistURL(label: label)
        return fileManager.fileExists(atPath: plistURL.path) || launchctlPrint()
    }

    private func launchctlPrint() -> Bool {
        runLaunchctl(arguments: ["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    private func runLaunchctlOrThrow(arguments: [String]) throws {
        let result = runLaunchctl(arguments: arguments)
        guard result.status == 0 else {
            throw LaunchAgentError.launchctlFailed(arguments: arguments, output: result.output)
        }
    }

    private func runLaunchctl(arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (1, "\(error)")
        }
    }

    private static func plistURL(label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
}

private enum LaunchAgentError: Error, CustomStringConvertible {
    case missingExecutableURL
    case launchctlFailed(arguments: [String], output: String)

    var description: String {
        switch self {
        case .missingExecutableURL:
            return "missing Bundle.main.executableURL"
        case .launchctlFailed(let arguments, let output):
            return "launchctl \(arguments.joined(separator: " ")) failed: \(output)"
        }
    }
}
