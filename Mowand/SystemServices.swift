import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Darwin
import Foundation
import IOKit
import ServiceManagement

@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
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
            try await execute(systemAction: action)
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

    private func execute(systemAction: SystemAction) async throws {
        switch systemAction {
        case .back:
            postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_LeftBracket), modifiers: ModifierFlags(command: true))
        case .forward:
            postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_RightBracket), modifiers: ModifierFlags(command: true))
        case .refresh:
            postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_R), modifiers: ModifierFlags(command: true))
        case .screenshotFullScreen:
            postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_3), modifiers: ModifierFlags(command: true, shift: true))
        case .screenshotSelection:
            postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_4), modifiers: ModifierFlags(command: true, shift: true))
        case .screenshot:
            postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_5), modifiers: ModifierFlags(command: true, shift: true))
        case .showDesktop:
            try sendDockNotification("com.apple.showdesktop.awake", fallback: {
                postKeyStroke(keyCode: CGKeyCode(kVK_F11), modifiers: ModifierFlags())
            })
        case .missionControl:
            try sendDockNotification("com.apple.expose.awake", fallback: {
                postKeyStroke(keyCode: CGKeyCode(kVK_F3), modifiers: ModifierFlags())
            })
        case .switchRecentApp:
            postKeyStroke(keyCode: CGKeyCode(kVK_Tab), modifiers: ModifierFlags(command: true))
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
            postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_Q), modifiers: ModifierFlags(command: true, control: true))
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

    private func sendDockNotification(_ name: String, fallback: () -> Void) throws {
        typealias CoreDockSendNotification = @convention(c) (CFString, Int32) -> Void
        let frameworkPath = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            fallback()
            throw ActionExecutionError.failed("无法载入系统调度服务")
        }
        guard let symbol = dlsym(handle, "CoreDockSendNotification") else {
            fallback()
            throw ActionExecutionError.failed("无法调用系统调度服务")
        }
        let sendNotification = unsafeBitCast(symbol, to: CoreDockSendNotification.self)
        sendNotification(name as CFString, 0)
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
