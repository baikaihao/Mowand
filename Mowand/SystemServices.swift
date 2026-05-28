import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import ServiceManagement

@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        refresh()
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var frontmostApplication: AppIdentity?
    @Published private(set) var runningApplications: [AppIdentity] = []
    @Published private(set) var launchAtLoginEnabled = false

    private var observers: [NSObjectProtocol] = []

    func start() {
        refreshApplications()
        refreshLaunchAtLogin()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        observers = names.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshApplications() }
            }
        }
    }

    func refreshFrontmostApplication() {
        refreshApplications()
    }

    func refreshApplications() {
        frontmostApplication = NSWorkspace.shared.frontmostApplication.map(AppIdentity.init(application:))
        runningApplications = NSWorkspace.shared.runningApplications
            .filter { application in
                application.activationPolicy == .regular
                    && application.bundleIdentifier != Bundle.main.bundleIdentifier
                    && application.bundleURL != nil
            }
            .map(AppIdentity.init(application:))
            .uniquedByID()
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLogin()
        } catch {
            launchAtLoginEnabled = false
        }
    }

    func refreshLaunchAtLogin() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }
}

private extension Array where Element == AppIdentity {
    func uniquedByID() -> [AppIdentity] {
        var seen = Set<String>()
        return filter { app in
            seen.insert(app.id).inserted
        }
    }
}

extension AppIdentity {
    init(application: NSRunningApplication) {
        self.init(
            bundleIdentifier: application.bundleIdentifier,
            displayName: application.localizedName ?? application.bundleIdentifier ?? "未知 App",
            path: application.bundleURL?.path
        )
    }

    init(url: URL) {
        let bundle = Bundle(url: url)
        self.init(
            bundleIdentifier: bundle?.bundleIdentifier,
            displayName: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent,
            path: url.path
        )
    }
}

@MainActor
final class ActionExecutor: ObservableObject {
    @Published private(set) var state: ActionExecutionState = .idle

    private var recentApplications: [NSRunningApplication] = []
    private var activationObserver: NSObjectProtocol?

    init() {
        if let application = NSWorkspace.shared.frontmostApplication {
            recordActivatedApplication(application)
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let processIdentifier = (
                notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            )?.processIdentifier else {
                return
            }

            Task { @MainActor [weak self] in
                guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
                    return
                }
                self?.recordActivatedApplication(application)
            }
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func execute(rule: GestureRule) async {
        state = .running(rule.name)
        for step in rule.actions where step.isEnabled {
            do {
                try await execute(step: step)
            } catch {
                state = .failed(error.localizedDescription)
                if step.failurePolicy == .stop {
                    return
                }
            }
        }
        state = .succeeded(rule.name)
    }

    private func execute(step: ActionStep) async throws {
        switch step.type {
        case .system(let action):
            try await execute(systemAction: action, screenshotExecutionMode: step.screenshotExecutionMode)
        case .keyboardShortcut(let keyStroke):
            postKeyStroke(keyCode: CGKeyCode(keyStroke.keyCode), modifiers: keyStroke.modifiers)
        case .openApplication(let app):
            try openApplication(app)
        case .openURL(let value):
            guard let url = URL(string: value), NSWorkspace.shared.open(url) else {
                throw ActionExecutionError.failed("无法打开 URL")
            }
        case .openFile(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .wait(let seconds):
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        case .shortcut(let name):
            try runShortcut(named: name)
        case .appleScript:
            throw ActionExecutionError.failed("AppleScript 动作将在后续版本支持")
        case .shellScript:
            throw ActionExecutionError.failed("Shell 脚本动作将在后续版本支持")
        }
    }

    private func execute(
        systemAction: SystemAction,
        screenshotExecutionMode: ScreenshotExecutionMode = .direct
    ) async throws {
        switch systemAction {
        case .copy:
            performMenuCommand(["Copy", "复制"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_C), modifiers: ModifierFlags(command: true))
            }
        case .paste:
            performMenuCommand(["Paste", "Paste and Match Style", "粘贴", "粘贴并匹配样式"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_V), modifiers: ModifierFlags(command: true))
            }
        case .cut:
            performMenuCommand(["Cut", "剪切"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_X), modifiers: ModifierFlags(command: true))
            }
        case .undo:
            performMenuCommand(["Undo", "Undo Typing", "撤销", "撤销键入"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_Z), modifiers: ModifierFlags(command: true))
            }
        case .redo:
            performMenuCommand(["Redo", "Redo Typing", "重做", "恢复"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_Z), modifiers: ModifierFlags(command: true, shift: true))
            }
        case .selectAll:
            performMenuCommand(["Select All", "全选"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: ModifierFlags(command: true))
            }
        case .find:
            performMenuCommand(["Find", "Find...", "Find…", "查找", "查找..."]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_F), modifiers: ModifierFlags(command: true))
            }
        case .save:
            performMenuCommand(["Save", "保存"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_S), modifiers: ModifierFlags(command: true))
            }
        case .newDocument:
            performMenuCommand(["New", "New Window", "New Document", "新建", "新建窗口", "新建文稿"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_N), modifiers: ModifierFlags(command: true))
            }
        case .open:
            performMenuCommand(["Open", "Open...", "Open…", "打开", "打开..."]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_O), modifiers: ModifierFlags(command: true))
            }
        case .closeWindow:
            performMenuCommand(["Close Window", "Close", "关闭窗口", "关闭"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_W), modifiers: ModifierFlags(command: true))
            }
        case .minimizeWindow:
            performMenuCommand(["Minimize", "最小化"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_M), modifiers: ModifierFlags(command: true))
            }
        case .hideApp:
            hideFrontmostApplication {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_H), modifiers: ModifierFlags(command: true))
            }
        case .quitApp:
            quitFrontmostApplication {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_Q), modifiers: ModifierFlags(command: true))
            }
        case .back:
            performMenuCommand(["Back", "Go Back", "返回", "后退"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_LeftBracket), modifiers: ModifierFlags(command: true))
            }
        case .forward:
            performMenuCommand(["Forward", "Go Forward", "前进"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_RightBracket), modifiers: ModifierFlags(command: true))
            }
        case .refresh:
            performMenuCommand(["Reload", "Reload Page", "Refresh", "刷新", "重新载入"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_R), modifiers: ModifierFlags(command: true))
            }
        case .screenshotFullScreen:
            if screenshotExecutionMode == .shortcut {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_3), modifiers: ModifierFlags(command: true, shift: true))
            } else {
                try captureScreenshot(arguments: ["-x"])
            }
        case .screenshotSelection:
            if screenshotExecutionMode == .shortcut {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_4), modifiers: ModifierFlags(command: true, shift: true))
            } else {
                try captureScreenshot(arguments: ["-i", "-s"])
            }
        case .screenshot:
            if screenshotExecutionMode == .shortcut {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_5), modifiers: ModifierFlags(command: true, shift: true))
            } else {
                openScreenshotPanel {
                    postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_5), modifiers: ModifierFlags(command: true, shift: true))
                }
            }
        case .showDesktop:
            sendDockNotification("com.apple.showdesktop.awake", fallback: {
                postKeyStroke(keyCode: CGKeyCode(kVK_F11), modifiers: ModifierFlags())
            })
        case .missionControl:
            sendDockNotification("com.apple.expose.awake", fallback: {
                postKeyStroke(keyCode: CGKeyCode(kVK_F3), modifiers: ModifierFlags())
            })
        case .switchRecentApp:
            switchToRecentApplication {
                postKeyStroke(keyCode: CGKeyCode(kVK_Tab), modifiers: ModifierFlags(command: true))
            }
        case .volumeUp:
            postSystemDefinedKey(NX_KEYTYPE_SOUND_UP)
        case .volumeDown:
            postSystemDefinedKey(NX_KEYTYPE_SOUND_DOWN)
        case .mute:
            postSystemDefinedKey(NX_KEYTYPE_MUTE)
        case .brightnessUp:
            postSystemDefinedKey(NX_KEYTYPE_BRIGHTNESS_UP)
        case .brightnessDown:
            postSystemDefinedKey(NX_KEYTYPE_BRIGHTNESS_DOWN)
        case .lockScreen:
            performMenuCommand(["Lock Screen", "锁定屏幕"]) {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_Q), modifiers: ModifierFlags(command: true, control: true))
            }
        case .systemSleep:
            try sleepSystem()
        }
    }

    private func openApplication(_ app: AppIdentity) throws {
        if let path = app.path {
            let url = URL(fileURLWithPath: path)
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }
        if let bundleIdentifier = app.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }
        throw ActionExecutionError.failed("找不到 App")
    }

    private func runShortcut(named name: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        try process.run()
    }

    private func captureScreenshot(arguments: [String]) throws {
        let fileURL = try nextScreenshotFileURL()
        try runProcess(at: "/usr/sbin/screencapture", arguments: arguments + [fileURL.path])
    }

    private func nextScreenshotFileURL() throws -> URL {
        let directory = screenshotDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let baseName = "Screenshot \(formatter.string(from: Date()))"

        var fileURL = directory.appendingPathComponent("\(baseName).png")
        var duplicateIndex = 2
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = directory.appendingPathComponent("\(baseName) \(duplicateIndex).png")
            duplicateIndex += 1
        }
        return fileURL
    }

    private func screenshotDirectoryURL() -> URL {
        if let location = UserDefaults.standard.persistentDomain(forName: "com.apple.screencapture")?["location"] as? String,
           !location.isEmpty {
            return URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
        }

        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    private func runProcess(at path: String, arguments: [String]) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ActionExecutionError.failed("找不到系统工具：\(path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
    }

    private func sleepSystem() throws {
        let powerManagementPort = IOPMFindPowerManagement(0)
        guard powerManagementPort != 0 else {
            throw ActionExecutionError.failed("无法连接电源管理服务")
        }
        defer { IOServiceClose(powerManagementPort) }

        let result = IOPMSleepSystem(powerManagementPort)
        guard result == kIOReturnSuccess else {
            throw ActionExecutionError.failed("系统睡眠失败：\(result)")
        }
    }

    private func openScreenshotPanel(fallback: () -> Void) {
        let screenshotAppURL = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        guard FileManager.default.fileExists(atPath: screenshotAppURL.path),
              NSWorkspace.shared.open(screenshotAppURL) else {
            fallback()
            return
        }
    }

    private func sendDockNotification(_ name: String, fallback: () -> Void) {
        typealias CoreDockSendNotification = @convention(c) (CFString, Int32) -> Void
        let frameworkPath = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            fallback()
            return
        }
        guard let symbol = dlsym(handle, "CoreDockSendNotification") else {
            fallback()
            return
        }
        let sendNotification = unsafeBitCast(symbol, to: CoreDockSendNotification.self)
        sendNotification(name as CFString, 0)
    }

    private func performMenuCommand(_ titles: [String], fallback: () -> Void) {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication,
              performMenuCommand(titles, in: application) else {
            fallback()
            return
        }
    }

    private func performMenuCommand(_ titles: [String], in application: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBar = menuBarValue else {
            return false
        }
        return performMenuCommand(titles, inMenuElement: unsafeBitCast(menuBar, to: AXUIElement.self))
    }

    private func performMenuCommand(_ titles: [String], inMenuElement menuElement: AXUIElement) -> Bool {
        if menuItemMatches(menuElement, titles: titles),
           AXUIElementPerformAction(menuElement, kAXPressAction as CFString) == .success {
            return true
        }

        for child in accessibilityChildren(of: menuElement) {
            if performMenuCommand(titles, inMenuElement: child) {
                return true
            }
        }
        return false
    }

    private func accessibilityChildren(of element: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return []
        }
        return children
    }

    private func menuItemMatches(_ element: AXUIElement, titles: [String]) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              (roleValue as? String) == kAXMenuItemRole else {
            return false
        }

        var enabledValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledValue) == .success,
           let isEnabled = enabledValue as? Bool,
           !isEnabled {
            return false
        }

        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else {
            return false
        }

        return titles.contains { candidate in
            title == candidate || title.localizedCaseInsensitiveCompare(candidate) == .orderedSame
        }
    }

    private func hideFrontmostApplication(fallback: () -> Void) {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier,
              application.hide() else {
            fallback()
            return
        }
    }

    private func quitFrontmostApplication(fallback: () -> Void) {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier,
              application.terminate() else {
            fallback()
            return
        }
    }

    private func switchToRecentApplication(fallback: () -> Void) {
        pruneRecentApplications()

        let currentProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let application = recentApplications.first(where: { application in
            application.processIdentifier != currentProcessIdentifier
                && isSwitchableApplication(application)
        }) else {
            fallback()
            return
        }

        guard application.activate(options: [.activateAllWindows]) else {
            fallback()
            return
        }
    }

    private func recordActivatedApplication(_ application: NSRunningApplication) {
        guard isSwitchableApplication(application) else { return }

        recentApplications.removeAll { existingApplication in
            existingApplication.processIdentifier == application.processIdentifier
        }
        recentApplications.insert(application, at: 0)
        if recentApplications.count > 12 {
            recentApplications.removeSubrange(12...)
        }
    }

    private func pruneRecentApplications() {
        recentApplications.removeAll { !isSwitchableApplication($0) }
    }

    private func isSwitchableApplication(_ application: NSRunningApplication) -> Bool {
        application.activationPolicy == .regular
            && !application.isTerminated
            && application.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    private func postKeyStroke(keyCode: CGKeyCode, modifiers: ModifierFlags) {
        let flags = modifiers.cgFlags
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func postSystemDefinedKey(_ key: Int32) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (Int(key) << 16) | (0xA << 8),
            data2: -1
        )?.cgEvent
        let keyUp = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (Int(key) << 16) | (0xB << 8),
            data2: -1
        )?.cgEvent
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        _ = source
    }
}

enum ActionExecutionError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            message
        }
    }
}

extension ModifierFlags {
    var cgFlags: CGEventFlags {
        var flags = CGEventFlags()
        if command { flags.insert(.maskCommand) }
        if option { flags.insert(.maskAlternate) }
        if control { flags.insert(.maskControl) }
        if shift { flags.insert(.maskShift) }
        return flags
    }

    init(cgFlags: CGEventFlags) {
        self.init(
            command: cgFlags.contains(.maskCommand),
            option: cgFlags.contains(.maskAlternate),
            control: cgFlags.contains(.maskControl),
            shift: cgFlags.contains(.maskShift)
        )
    }
}
