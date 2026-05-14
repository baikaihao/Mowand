import Foundation
import SwiftUI

enum GestureDirection: String, Codable, CaseIterable, Identifiable, Hashable {
    case east
    case southEast
    case south
    case southWest
    case west
    case northWest
    case north
    case northEast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .east: "→ 右"
        case .southEast: "↘ 右下"
        case .south: "↓ 下"
        case .southWest: "↙ 左下"
        case .west: "← 左"
        case .northWest: "↖ 左上"
        case .north: "↑ 上"
        case .northEast: "↗ 右上"
        }
    }

    var textTitle: String {
        switch self {
        case .east: "右"
        case .southEast: "右下"
        case .south: "下"
        case .southWest: "左下"
        case .west: "左"
        case .northWest: "左上"
        case .north: "上"
        case .northEast: "右上"
        }
    }

    var symbolName: String {
        switch self {
        case .east: "arrow.right"
        case .southEast: "arrow.down.right"
        case .south: "arrow.down"
        case .southWest: "arrow.down.left"
        case .west: "arrow.left"
        case .northWest: "arrow.up.left"
        case .north: "arrow.up"
        case .northEast: "arrow.up.right"
        }
    }

    var angleDegrees: Double {
        switch self {
        case .east: 0
        case .southEast: 45
        case .south: 90
        case .southWest: 135
        case .west: 180
        case .northWest: 225
        case .north: 270
        case .northEast: 315
        }
    }

    nonisolated static func from(delta: CGSize) -> GestureDirection? {
        let distance = hypot(delta.width, delta.height)
        guard distance >= 1 else { return nil }

        let radians = atan2(delta.height, delta.width)
        var degrees = radians * 180 / .pi
        if degrees < 0 { degrees += 360 }

        switch degrees {
        case 337.5...360, 0..<22.5:
            return .east
        case 22.5..<67.5:
            return .southEast
        case 67.5..<112.5:
            return .south
        case 112.5..<157.5:
            return .southWest
        case 157.5..<202.5:
            return .west
        case 202.5..<247.5:
            return .northWest
        case 247.5..<292.5:
            return .north
        case 292.5..<337.5:
            return .northEast
        default:
            return nil
        }
    }

    nonisolated var components: (x: Int, y: Int) {
        switch self {
        case .east: (1, 0)
        case .southEast: (1, 1)
        case .south: (0, 1)
        case .southWest: (-1, 1)
        case .west: (-1, 0)
        case .northWest: (-1, -1)
        case .north: (0, -1)
        case .northEast: (1, -1)
        }
    }

    nonisolated var isDiagonal: Bool {
        components.x != 0 && components.y != 0
    }

    nonisolated func isDiagonalBridge(from previous: GestureDirection, to next: GestureDirection) -> Bool {
        guard isDiagonal, !previous.isDiagonal, !next.isDiagonal else { return false }
        let previousComponents = previous.components
        let nextComponents = next.components
        let currentComponents = components
        return currentComponents.x == previousComponents.x
            && currentComponents.y == nextComponents.y
            || currentComponents.y == previousComponents.y
            && currentComponents.x == nextComponents.x
    }
}

enum MouseTriggerButton: Codable, Hashable, Identifiable {
    case right
    case middle
    case auxiliary(Int64)

    var id: String { storageValue }

    var title: String {
        switch self {
        case .right: "右键"
        case .middle: "中键"
        case .auxiliary(let buttonNumber): "侧键 \(buttonNumber)"
        }
    }

    var buttonNumber: Int64 {
        switch self {
        case .right: 1
        case .middle: 2
        case .auxiliary(let buttonNumber): buttonNumber
        }
    }

    var isAuxiliary: Bool {
        if case .auxiliary = self {
            return true
        }
        return false
    }

    private var storageValue: String {
        switch self {
        case .right: "right"
        case .middle: "middle"
        case .auxiliary(let buttonNumber): "auxiliary:\(buttonNumber)"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "right":
            self = .right
        case "middle":
            self = .middle
        case "button4":
            self = .auxiliary(3)
        case "button5":
            self = .auxiliary(4)
        default:
            if value.hasPrefix("auxiliary:"),
               let buttonNumber = Int64(value.dropFirst("auxiliary:".count)),
               buttonNumber > 2 {
                self = .auxiliary(buttonNumber)
            } else {
                self = .right
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}

struct ModifierFlags: Codable, Hashable {
    var command: Bool = false
    var option: Bool = false
    var control: Bool = false
    var shift: Bool = false

    var title: String {
        var parts: [String] = []
        if command { parts.append("⌘") }
        if option { parts.append("⌥") }
        if control { parts.append("⌃") }
        if shift { parts.append("⇧") }
        return parts.isEmpty ? "无修饰键" : parts.joined(separator: " ")
    }
}

enum ScreenRegionKind: String, Codable, CaseIterable, Identifiable {
    case full
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "全屏"
        case .leftHalf: "左半屏"
        case .rightHalf: "右半屏"
        case .topHalf: "上半屏"
        case .bottomHalf: "下半屏"
        case .topLeftQuarter: "左上四分之一"
        case .topRightQuarter: "右上四分之一"
        case .bottomLeftQuarter: "左下四分之一"
        case .bottomRightQuarter: "右下四分之一"
        case .custom: "自定义范围"
        }
    }
}

struct NormalizedRect: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    var isValid: Bool {
        width > 0 && height > 0 && x >= 0 && y >= 0 && x + width <= 1.0001 && y + height <= 1.0001
    }
}

struct ScreenRegion: Codable, Hashable {
    var kind: ScreenRegionKind
    var customRect: NormalizedRect?

    static let full = ScreenRegion(kind: .full)

    var title: String { kind.title }
}

enum GestureScope: Codable, Hashable {
    case global
    case application(AppIdentity)

    private enum CodingKeys: String, CodingKey {
        case type
        case application
    }

    private enum ScopeType: String, Codable {
        case global
        case application
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ScopeType.self, forKey: .type)
        switch type {
        case .global:
            self = .global
        case .application:
            self = .application(try container.decode(AppIdentity.self, forKey: .application))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode(ScopeType.global, forKey: .type)
        case .application(let identity):
            try container.encode(ScopeType.application, forKey: .type)
            try container.encode(identity, forKey: .application)
        }
    }

    var title: String {
        switch self {
        case .global:
            "全局"
        case .application(let identity):
            identity.displayName
        }
    }

    var bundleIdentifier: String? {
        if case .application(let identity) = self {
            identity.bundleIdentifier
        } else {
            nil
        }
    }
}

struct AppIdentity: Codable, Hashable, Identifiable {
    var bundleIdentifier: String?
    var displayName: String
    var path: String?

    var id: String { bundleIdentifier ?? path ?? displayName }
}

enum FailurePolicy: String, Codable, CaseIterable, Identifiable {
    case stop
    case continueNext

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stop: "失败时中断"
        case .continueNext: "失败后继续"
        }
    }
}

struct GestureRule: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var scope: GestureScope
    var triggerButton: MouseTriggerButton
    var modifiers: ModifierFlags
    var region: ScreenRegion
    var directions: [GestureDirection]
    var actions: [ActionStep]
    var createdAt: Date
    var updatedAt: Date
    var isDefaultTemplate: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isEnabled
        case scope
        case triggerButton
        case modifiers
        case region
        case directions
        case actions
        case createdAt
        case updatedAt
        case isDefaultTemplate
    }

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        scope: GestureScope = .global,
        triggerButton: MouseTriggerButton = .right,
        modifiers: ModifierFlags = ModifierFlags(),
        region: ScreenRegion = .full,
        directions: [GestureDirection],
        actions: [ActionStep],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isDefaultTemplate: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.scope = scope
        self.triggerButton = triggerButton
        self.modifiers = modifiers
        self.region = region
        self.directions = directions
        self.actions = actions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDefaultTemplate = isDefaultTemplate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        scope = try container.decode(GestureScope.self, forKey: .scope)
        triggerButton = try container.decode(MouseTriggerButton.self, forKey: .triggerButton)
        modifiers = try container.decode(ModifierFlags.self, forKey: .modifiers)
        region = try container.decode(ScreenRegion.self, forKey: .region)
        directions = try container.decode([GestureDirection].self, forKey: .directions)
        actions = try container.decode([ActionStep].self, forKey: .actions)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isDefaultTemplate = try container.decode(Bool.self, forKey: .isDefaultTemplate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(scope, forKey: .scope)
        try container.encode(triggerButton, forKey: .triggerButton)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(region, forKey: .region)
        try container.encode(directions, forKey: .directions)
        try container.encode(actions, forKey: .actions)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isDefaultTemplate, forKey: .isDefaultTemplate)
    }

    var gestureTitle: String {
        directions.map(\.title).joined(separator: " -> ")
    }

    var actionTitle: String {
        actions.map(\.title).joined(separator: " -> ")
    }
}

struct ActionStep: Codable, Identifiable, Hashable {
    var id: UUID
    var type: ActionType
    var failurePolicy: FailurePolicy
    var isEnabled: Bool

    init(id: UUID = UUID(), type: ActionType, failurePolicy: FailurePolicy = .stop, isEnabled: Bool = true) {
        self.id = id
        self.type = type
        self.failurePolicy = failurePolicy
        self.isEnabled = isEnabled
    }

    var title: String { type.title }
}

enum SystemAction: String, Codable, CaseIterable, Identifiable {
    case back
    case forward
    case refresh
    case screenshotFullScreen
    case screenshotSelection
    case screenshot
    case showDesktop
    case missionControl
    case switchRecentApp
    case volumeUp
    case volumeDown
    case mute
    case brightnessUp
    case brightnessDown
    case lockScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .back: "返回"
        case .forward: "前进"
        case .refresh: "刷新"
        case .screenshotFullScreen: "全屏截图（直接保存，⌘⇧3）"
        case .screenshotSelection: "选区截图（拖拽区域，⌘⇧4）"
        case .screenshot: "截图工具（完整面板，⌘⇧5）"
        case .showDesktop: "显示桌面"
        case .missionControl: "调度中心"
        case .switchRecentApp: "切换最近使用的 App"
        case .volumeUp: "提高音量"
        case .volumeDown: "降低音量"
        case .mute: "静音"
        case .brightnessUp: "提高亮度"
        case .brightnessDown: "降低亮度"
        case .lockScreen: "锁屏"
        }
    }

    var symbolName: String {
        switch self {
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .refresh: "arrow.clockwise"
        case .screenshotFullScreen: "camera"
        case .screenshotSelection: "crop"
        case .screenshot: "camera.viewfinder"
        case .showDesktop: "rectangle.dashed"
        case .missionControl: "rectangle.3.group"
        case .switchRecentApp: "app.connected.to.app.below.fill"
        case .volumeUp: "speaker.wave.3"
        case .volumeDown: "speaker.wave.1"
        case .mute: "speaker.slash"
        case .brightnessUp: "sun.max"
        case .brightnessDown: "sun.min"
        case .lockScreen: "lock"
        }
    }
}

struct KeyStroke: Codable, Hashable {
    var keyCode: Int
    var keyLabel: String
    var modifiers: ModifierFlags
}

enum ActionType: Codable, Hashable {
    case system(SystemAction)
    case keyboardShortcut(KeyStroke)
    case openApplication(AppIdentity)
    case openURL(String)
    case openFile(String)
    case wait(TimeInterval)
    case shortcut(String)
    case appleScript(String, isEnabled: Bool)
    case shellScript(String, isEnabled: Bool)

    private enum CodingKeys: String, CodingKey {
        case type
        case system
        case keyStroke
        case application
        case url
        case filePath
        case seconds
        case shortcutName
        case script
        case isEnabled
    }

    private enum Kind: String, Codable {
        case system
        case keyboardShortcut
        case openApplication
        case openURL
        case openFile
        case wait
        case shortcut
        case appleScript
        case shellScript
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .system:
            self = .system(try container.decode(SystemAction.self, forKey: .system))
        case .keyboardShortcut:
            self = .keyboardShortcut(try container.decode(KeyStroke.self, forKey: .keyStroke))
        case .openApplication:
            self = .openApplication(try container.decode(AppIdentity.self, forKey: .application))
        case .openURL:
            self = .openURL(try container.decode(String.self, forKey: .url))
        case .openFile:
            self = .openFile(try container.decode(String.self, forKey: .filePath))
        case .wait:
            self = .wait(try container.decode(TimeInterval.self, forKey: .seconds))
        case .shortcut:
            self = .shortcut(try container.decode(String.self, forKey: .shortcutName))
        case .appleScript:
            self = .appleScript(
                try container.decode(String.self, forKey: .script),
                isEnabled: try container.decode(Bool.self, forKey: .isEnabled)
            )
        case .shellScript:
            self = .shellScript(
                try container.decode(String.self, forKey: .script),
                isEnabled: try container.decode(Bool.self, forKey: .isEnabled)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system(let action):
            try container.encode(Kind.system, forKey: .type)
            try container.encode(action, forKey: .system)
        case .keyboardShortcut(let keyStroke):
            try container.encode(Kind.keyboardShortcut, forKey: .type)
            try container.encode(keyStroke, forKey: .keyStroke)
        case .openApplication(let application):
            try container.encode(Kind.openApplication, forKey: .type)
            try container.encode(application, forKey: .application)
        case .openURL(let url):
            try container.encode(Kind.openURL, forKey: .type)
            try container.encode(url, forKey: .url)
        case .openFile(let path):
            try container.encode(Kind.openFile, forKey: .type)
            try container.encode(path, forKey: .filePath)
        case .wait(let seconds):
            try container.encode(Kind.wait, forKey: .type)
            try container.encode(seconds, forKey: .seconds)
        case .shortcut(let name):
            try container.encode(Kind.shortcut, forKey: .type)
            try container.encode(name, forKey: .shortcutName)
        case .appleScript(let script, let isEnabled):
            try container.encode(Kind.appleScript, forKey: .type)
            try container.encode(script, forKey: .script)
            try container.encode(isEnabled, forKey: .isEnabled)
        case .shellScript(let script, let isEnabled):
            try container.encode(Kind.shellScript, forKey: .type)
            try container.encode(script, forKey: .script)
            try container.encode(isEnabled, forKey: .isEnabled)
        }
    }

    var title: String {
        switch self {
        case .system(let action):
            action.title
        case .keyboardShortcut(let keyStroke):
            "\(keyStroke.modifiers.title) \(keyStroke.keyLabel)"
        case .openApplication(let app):
            "打开 \(app.displayName)"
        case .openURL(let url):
            "打开 URL \(url)"
        case .openFile(let path):
            "打开 \(URL(fileURLWithPath: path).lastPathComponent)"
        case .wait(let seconds):
            "等待 \(String(format: "%.1f", seconds)) 秒"
        case .shortcut(let name):
            "快捷指令 \(name)"
        case .appleScript:
            "AppleScript（后续支持）"
        case .shellScript:
            "Shell 脚本（后续支持）"
        }
    }
}

struct AppSettings: Codable, Hashable {
    var gesturesEnabled: Bool = true
    var hudEnabled: Bool = true
    var hudOnlyForErrors: Bool = false
    var hudDismissDelay: TimeInterval = 0.9
    var hudFadeDuration: TimeInterval = 0.15
    var hudStyle: HUDSettings = HUDSettings()
    var triggerButton: MouseTriggerButton = .right
    var triggerModifiers: ModifierFlags = ModifierFlags()
    var movementThreshold: Double = 12
    var segmentMinDistance: Double = 18
    var launchAtLogin: Bool = false
    var showDockIcon: Bool = true

    private enum CodingKeys: String, CodingKey {
        case gesturesEnabled
        case hudEnabled
        case hudOnlyForErrors
        case hudDismissDelay
        case hudFadeDuration
        case hudStyle
        case triggerButton
        case triggerModifiers
        case movementThreshold
        case segmentMinDistance
        case launchAtLogin
        case showDockIcon
    }

    init() {}

    init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gesturesEnabled = try container.decodeIfPresent(Bool.self, forKey: .gesturesEnabled) ?? defaults.gesturesEnabled
        hudEnabled = try container.decodeIfPresent(Bool.self, forKey: .hudEnabled) ?? defaults.hudEnabled
        hudOnlyForErrors = try container.decodeIfPresent(Bool.self, forKey: .hudOnlyForErrors) ?? defaults.hudOnlyForErrors
        hudDismissDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .hudDismissDelay) ?? defaults.hudDismissDelay
        hudFadeDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .hudFadeDuration) ?? defaults.hudFadeDuration
        hudStyle = try container.decodeIfPresent(HUDSettings.self, forKey: .hudStyle) ?? defaults.hudStyle
        triggerButton = try container.decodeIfPresent(MouseTriggerButton.self, forKey: .triggerButton) ?? defaults.triggerButton
        triggerModifiers = try container.decodeIfPresent(ModifierFlags.self, forKey: .triggerModifiers) ?? defaults.triggerModifiers
        movementThreshold = try container.decodeIfPresent(Double.self, forKey: .movementThreshold) ?? defaults.movementThreshold
        segmentMinDistance = try container.decodeIfPresent(Double.self, forKey: .segmentMinDistance) ?? defaults.segmentMinDistance
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? defaults.showDockIcon
    }
}

enum HUDColorPreset: String, Codable, CaseIterable, Identifiable, Hashable {
    case blue
    case cyan
    case green
    case orange
    case red
    case purple
    case white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: "蓝"
        case .cyan: "青"
        case .green: "绿"
        case .orange: "橙"
        case .red: "红"
        case .purple: "紫"
        case .white: "白"
        }
    }

    var color: Color {
        switch self {
        case .blue: .blue
        case .cyan: .cyan
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .purple: .purple
        case .white: .white
        }
    }
}

enum HUDPanelBackgroundStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    case transparentGlass
    case frostedGlass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transparentGlass: "透明玻璃"
        case .frostedGlass: "磨砂玻璃"
        }
    }
}

struct HUDSettings: Codable, Hashable {
    var showTrajectory: Bool = true
    var showDirectionGuide: Bool = true
    var directionGuideRadius: Double = 72
    var directionGuideSmoothing: Double = 0.2
    var directionGuideOpacity: Double = 0.72
    var directionGuideLineWidth: Double = 1.5
    var directionGuideArrowSize: Double = 13
    var directionGuideFontSize: Double = 9
    var highlightedColor: HUDColorPreset = .blue
    var normalLineColor: HUDColorPreset = .white
    var showDirectionLabels: Bool = true
    var showDirectionArrows: Bool = true
    var panelBackgroundStyle: HUDPanelBackgroundStyle = .transparentGlass

    private enum CodingKeys: String, CodingKey {
        case showTrajectory
        case showDirectionGuide
        case directionGuideRadius
        case directionGuideSmoothing
        case directionGuideFollowDelay
        case directionGuideOpacity
        case directionGuideLineWidth
        case directionGuideArrowSize
        case directionGuideFontSize
        case highlightedColor
        case normalLineColor
        case showDirectionLabels
        case showDirectionArrows
        case panelBackgroundStyle
    }

    init() {}

    init(from decoder: Decoder) throws {
        let defaults = HUDSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showTrajectory = try container.decodeIfPresent(Bool.self, forKey: .showTrajectory) ?? defaults.showTrajectory
        showDirectionGuide = try container.decodeIfPresent(Bool.self, forKey: .showDirectionGuide) ?? defaults.showDirectionGuide
        directionGuideRadius = try container.decodeIfPresent(Double.self, forKey: .directionGuideRadius) ?? defaults.directionGuideRadius
        directionGuideSmoothing = try container.decodeIfPresent(Double.self, forKey: .directionGuideSmoothing)
            ?? container.decodeIfPresent(Double.self, forKey: .directionGuideFollowDelay)
            ?? defaults.directionGuideSmoothing
        directionGuideOpacity = try container.decodeIfPresent(Double.self, forKey: .directionGuideOpacity) ?? defaults.directionGuideOpacity
        directionGuideLineWidth = try container.decodeIfPresent(Double.self, forKey: .directionGuideLineWidth) ?? defaults.directionGuideLineWidth
        directionGuideArrowSize = try container.decodeIfPresent(Double.self, forKey: .directionGuideArrowSize) ?? defaults.directionGuideArrowSize
        directionGuideFontSize = try container.decodeIfPresent(Double.self, forKey: .directionGuideFontSize) ?? defaults.directionGuideFontSize
        highlightedColor = try container.decodeIfPresent(HUDColorPreset.self, forKey: .highlightedColor) ?? defaults.highlightedColor
        normalLineColor = try container.decodeIfPresent(HUDColorPreset.self, forKey: .normalLineColor) ?? defaults.normalLineColor
        showDirectionLabels = try container.decodeIfPresent(Bool.self, forKey: .showDirectionLabels) ?? defaults.showDirectionLabels
        showDirectionArrows = try container.decodeIfPresent(Bool.self, forKey: .showDirectionArrows) ?? defaults.showDirectionArrows
        panelBackgroundStyle = try container.decodeIfPresent(HUDPanelBackgroundStyle.self, forKey: .panelBackgroundStyle) ?? defaults.panelBackgroundStyle
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showTrajectory, forKey: .showTrajectory)
        try container.encode(showDirectionGuide, forKey: .showDirectionGuide)
        try container.encode(directionGuideRadius, forKey: .directionGuideRadius)
        try container.encode(directionGuideSmoothing, forKey: .directionGuideSmoothing)
        try container.encode(directionGuideOpacity, forKey: .directionGuideOpacity)
        try container.encode(directionGuideLineWidth, forKey: .directionGuideLineWidth)
        try container.encode(directionGuideArrowSize, forKey: .directionGuideArrowSize)
        try container.encode(directionGuideFontSize, forKey: .directionGuideFontSize)
        try container.encode(highlightedColor, forKey: .highlightedColor)
        try container.encode(normalLineColor, forKey: .normalLineColor)
        try container.encode(showDirectionLabels, forKey: .showDirectionLabels)
        try container.encode(showDirectionArrows, forKey: .showDirectionArrows)
        try container.encode(panelBackgroundStyle, forKey: .panelBackgroundStyle)
    }
}

struct MowandConfiguration: Codable {
    var schemaVersion: Int
    var hasInstalledDefaultTemplates: Bool
    var settings: AppSettings
    var rules: [GestureRule]
    var excludedApplications: [AppIdentity]

    static let currentSchemaVersion = 1

    static var empty: MowandConfiguration {
        MowandConfiguration(
            schemaVersion: currentSchemaVersion,
            hasInstalledDefaultTemplates: false,
            settings: AppSettings(),
            rules: [],
            excludedApplications: []
        )
    }
}

enum ActionExecutionState: Equatable {
    case idle
    case running(String)
    case succeeded(String)
    case failed(String)
}

struct GestureMatch {
    var rule: GestureRule
    var isApplicationSpecific: Bool
    var recognition: GestureRecognitionKind = .directionChain
}

enum GestureRecognitionKind {
    case directionChain
    case template
}
