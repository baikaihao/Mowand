import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var permissions: PermissionMonitor
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var gestureEngine: GestureEngine
    @EnvironmentObject private var actionExecutor: ActionExecutor
    @EnvironmentObject private var rangeSelector: RangeSelectionCoordinator

    @State private var selectedPage: SettingsPage = .gestures
    @State private var selectedRuleID: GestureRule.ID?

    var body: some View {
        NavigationSplitView {
            Sidebar(selectedPage: $selectedPage)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            Group {
                switch selectedPage {
                case .gestures:
                    GesturesPage(selectedRuleID: $selectedRuleID)
                case .hud:
                    HUDSettingsPage()
                case .applications:
                    ApplicationsPage()
                case .general:
                    GeneralSettingsPage()
                }
            }
            .frame(minWidth: 760, minHeight: 540)
        }
        .overlay(alignment: .top) {
            if !permissions.accessibilityGranted {
                PermissionBanner()
                    .padding(.top, 12)
            }
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case gestures
    case hud
    case applications
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gestures: "手势"
        case .hud: "HUD"
        case .applications: "应用规则"
        case .general: "通用设置"
        }
    }

    var symbolName: String {
        switch self {
        case .gestures: "wand.and.stars"
        case .hud: "scope"
        case .applications: "app.badge"
        case .general: "gearshape"
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var store: ConfigurationStore

    @Binding var selectedPage: SettingsPage

    var body: some View {
        List(SettingsPage.allCases, selection: $selectedPage) { page in
            Label(page.title, systemImage: page.symbolName)
                .tag(page)
        }
        .navigationTitle("Mowand")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: gesturesEnabledBinding) {
                    Label("全局手势", systemImage: store.settings.gesturesEnabled ? "wand.and.stars" : "wand.and.stars.inverse")
                }
                .toggleStyle(.switch)

                Divider()

                Text("魔杖")
                    .font(.headline)
                Text("右键拖动绘制八方向手势")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var gesturesEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.gesturesEnabled },
            set: { enabled in store.updateSettings { $0.gesturesEnabled = enabled } }
        )
    }
}

private struct PermissionBanner: View {
    @EnvironmentObject private var permissions: PermissionMonitor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "accessibility")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("需要辅助功能权限")
                    .font(.headline)
                Text("全局鼠标监听和快捷键模拟依赖此权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开授权") {
                permissions.requestAccessibilityPermission()
            }
            .buttonStyle(AuthorizationButtonStyle())
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 18)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

private struct AuthorizationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.82 : 1))
            )
            .shadow(color: .black.opacity(configuration.isPressed ? 0.04 : 0.08), radius: 2, y: 1)
    }
}

private struct GesturesPage: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var rangeSelector: RangeSelectionCoordinator
    @Binding var selectedRuleID: GestureRule.ID?

    @State private var draft: GestureRule?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("手势列表")
                .font(.largeTitle.bold())

            HSplitView {
                VStack(spacing: 0) {
                    header
                    List(selection: $selectedRuleID) {
                        ForEach(store.rules) { rule in
                            RuleRow(rule: rule)
                                .tag(rule.id)
                        }
                    }
                    .onChange(of: selectedRuleID) { _, newValue in
                        draft = store.rules.first(where: { $0.id == newValue })
                    }
                }
                .frame(minWidth: 310, idealWidth: 360)

                if let draft {
                    RuleEditor(rule: binding(for: draft))
                        .frame(minWidth: 440)
                } else {
                    EmptySelectionView(
                        title: "选择或新建手势",
                        subtitle: "默认模板已自动创建，可直接修改动作与触发条件。",
                        systemImage: "wand.and.stars"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 24)
        .padding(.leading, 61)
        .padding(.trailing, 24)
        .onAppear {
            if selectedRuleID == nil {
                selectedRuleID = store.rules.first?.id
            }
            draft = store.rules.first(where: { $0.id == selectedRuleID })
        }
    }

    private var header: some View {
        HStack {
            Text("规则")
                .font(.headline)
            Spacer()
            Button {
                let rule = GestureRule(
                    name: "新手势",
                    directions: [.east],
                    actions: [ActionStep(type: .system(.refresh))]
                )
                store.upsertRule(rule)
                selectedRuleID = rule.id
                draft = rule
            } label: {
                Label("新增", systemImage: "plus")
            }
            Button {
                if selectedRule != nil { showingDeleteConfirmation = true }
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selectedRule == nil)
            .confirmationDialog("删除手势？", isPresented: $showingDeleteConfirmation) {
                Button("删除", role: .destructive) {
                    if let selectedRule {
                        store.deleteRule(selectedRule)
                        selectedRuleID = store.rules.first?.id
                        draft = store.rules.first
                    }
                }
            }
        }
        .padding(12)
    }

    private var selectedRule: GestureRule? {
        store.rules.first(where: { $0.id == selectedRuleID })
    }

    private func binding(for rule: GestureRule) -> Binding<GestureRule> {
        Binding(
            get: { store.rules.first(where: { $0.id == rule.id }) ?? rule },
            set: { updated in
                store.upsertRule(updated)
                draft = updated
            }
        )
    }
}

private struct RuleRow: View {
    let rule: GestureRule

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(rule.name)
                    .font(.headline)
                Spacer()
                if rule.isDefaultTemplate {
                    Text("默认")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.14), in: Capsule())
                }
            }
            Text(rule.gestureTitle)
                .font(.subheadline)
            Text("\(rule.scope.title) · \(rule.region.title) · \(rule.actionTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .opacity(rule.isEnabled ? 1 : 0.45)
    }
}

private struct RuleEditor: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var rangeSelector: RangeSelectionCoordinator
    @Binding var rule: GestureRule

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeader("基础")
                Toggle("启用此手势", isOn: $rule.isEnabled)
                HStack {
                    Text("手势名")
                        .frame(width: 72, alignment: .leading)
                    TextField("手势名", text: $rule.name)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("分配动作")
                        .frame(width: 72, alignment: .leading)
                    Picker("分配动作", selection: assignedSystemActionBinding) {
                        ForEach(SystemAction.allCases) { action in
                            Label(action.title, systemImage: action.symbolName)
                                .tag(action)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Picker("作用域", selection: scopeBinding) {
                    Text("全局").tag("global")
                    Text("当前前台 App").tag("frontmost")
                }
                .pickerStyle(.segmented)

                SectionHeader("触发")
                Picker("鼠标按钮", selection: $rule.triggerButton) {
                    ForEach(MouseTriggerButton.allCases) { button in
                        Text(button.title).tag(button)
                    }
                }
                .pickerStyle(.segmented)

                ModifierEditor(modifiers: $rule.modifiers)

                SectionHeader("方向序列")
                DirectionSequenceEditor(directions: $rule.directions)

                SectionHeader("屏幕区域")
                RegionEditor(region: $rule.region)

                if !store.conflictingRules(for: rule).isEmpty {
                    Label("存在同作用域、同触发条件和同方向序列的冲突规则", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .padding(24)
        }
    }

    private var assignedSystemActionBinding: Binding<SystemAction> {
        Binding(
            get: {
                guard rule.actions.count == 1,
                      case .system(let action) = rule.actions[0].type else {
                    return .back
                }
                return action
            },
            set: { action in
                rule.name = action.title
                rule.actions = [ActionStep(type: .system(action))]
            }
        )
    }

    private var scopeBinding: Binding<String> {
        Binding(
            get: {
                if case .global = rule.scope { return "global" }
                return "frontmost"
            },
            set: { value in
                if value == "global" {
                    rule.scope = .global
                } else {
                    let app = NSWorkspace.shared.frontmostApplication.map { AppIdentity(application: $0) }
                        ?? AppIdentity(bundleIdentifier: nil, displayName: "当前 App", path: nil)
                    rule.scope = .application(app)
                }
            }
        )
    }
}

private struct ModifierEditor: View {
    @Binding var modifiers: ModifierFlags

    var body: some View {
        HStack {
            Toggle("⌘", isOn: $modifiers.command)
            Toggle("⌥", isOn: $modifiers.option)
            Toggle("⌃", isOn: $modifiers.control)
            Toggle("⇧", isOn: $modifiers.shift)
        }
        .toggleStyle(.button)
    }
}

private struct DirectionSequenceEditor: View {
    @Binding var directions: [GestureDirection]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(directions.indices, id: \.self) { index in
                    Menu {
                        ForEach(GestureDirection.allCases) { direction in
                            Button(direction.title) {
                                directions[index] = direction
                            }
                        }
                        Divider()
                        Button("删除", role: .destructive) {
                            directions.remove(at: index)
                        }
                    } label: {
                        Text(directions[index].title)
                    }
                }
                Button {
                    directions.append(.east)
                } label: {
                    Label("添加方向", systemImage: "plus")
                }
            }
            Text("连续相同方向会在识别时自动合并。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RegionEditor: View {
    @EnvironmentObject private var rangeSelector: RangeSelectionCoordinator
    @Binding var region: ScreenRegion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("区域", selection: $region.kind) {
                ForEach(ScreenRegionKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)

            if region.kind == .custom {
                HStack {
                    Button {
                        rangeSelector.selectRange { rect in
                            if let rect {
                                region.customRect = rect
                            }
                        }
                    } label: {
                        Label("选择屏幕范围", systemImage: "crop")
                    }
                    if let rect = region.customRect {
                        Text("x \(rect.x.formatted(.number.precision(.fractionLength(2)))) · y \(rect.y.formatted(.number.precision(.fractionLength(2)))) · w \(rect.width.formatted(.number.precision(.fractionLength(2)))) · h \(rect.height.formatted(.number.precision(.fractionLength(2))))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                RegionPreview(region: region)
                    .frame(width: 220, height: 124)
            }
        }
    }
}

private struct RegionPreview: View {
    let region: ScreenRegion

    var body: some View {
        GeometryReader { proxy in
            let rect = previewRect(in: proxy.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }

    private func previewRect(in size: CGSize) -> CGRect {
        let normalized = region.customRect ?? .full
        return CGRect(
            x: size.width * normalized.x,
            y: size.height * normalized.y,
            width: size.width * normalized.width,
            height: size.height * normalized.height
        )
    }
}

private struct ApplicationsPage: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var appEnvironment: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("应用规则")
                .font(.largeTitle.bold())

            GroupBox("当前运行的 App") {
                if appEnvironment.runningApplications.isEmpty {
                    Text("暂无可选择的运行中 App。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                } else {
                    List(appEnvironment.runningApplications) { app in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(app.displayName)
                                    .font(.headline)
                                Text(app.bundleIdentifier ?? app.path ?? "无标识")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(isExcluded(app) ? "已加入" : "加入排除列表") {
                                store.addExcludedApplication(app)
                            }
                            .disabled(isExcluded(app))
                        }
                    }
                    .frame(minHeight: 180, idealHeight: 240)
                }
            }

            GroupBox("排除全局手势的 App") {
                if store.excludedApplications.isEmpty {
                    Text("暂无排除项。应用专属规则仍会优先触发。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    List(store.excludedApplications) { app in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(app.displayName)
                                Text(app.bundleIdentifier ?? app.path ?? "无标识")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                store.removeExcludedApplication(app)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(minHeight: 180)
                }
            }

            Spacer()
        }
        .padding(24)
    }

    private func isExcluded(_ app: AppIdentity) -> Bool {
        store.excludedApplications.contains { excluded in
            excluded.id == app.id
        }
    }
}

private struct HUDSettingsPage: View {
    @EnvironmentObject private var store: ConfigurationStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("HUD")
                    .font(.largeTitle.bold())

                HUDPreview(style: store.settings.hudStyle)
                    .frame(height: 260)

                GroupBox("显示") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("显示 HUD", isOn: settingsBinding(\.hudEnabled))
                        Toggle("仅错误时显示 HUD", isOn: settingsBinding(\.hudOnlyForErrors))
                        Toggle("显示轨迹", isOn: hudBinding(\.showTrajectory))
                        Toggle("显示方向范围", isOn: hudBinding(\.showDirectionGuide))
                        Toggle("显示方向文字", isOn: hudBinding(\.showDirectionLabels))
                        Toggle("显示方向箭头", isOn: hudBinding(\.showDirectionArrows))
                        SliderRow(title: "停留时间", value: settingsBinding(\.hudDismissDelay), range: 0.1...2, suffix: "秒")
                        SliderRow(title: "淡出时间", value: settingsBinding(\.hudFadeDuration), range: 0.05...0.6, suffix: "秒", precision: 2)
                    }
                    .padding(4)
                }

                GroupBox("方向范围") {
                    VStack(alignment: .leading, spacing: 14) {
                        SliderRow(title: "半径", value: hudBinding(\.directionGuideRadius), range: 20...128, suffix: "px")
                        SliderRow(title: "跟随平滑度", value: hudBinding(\.directionGuideSmoothing), range: 0...0.6, suffix: "")
                        SliderRow(title: "透明度", value: hudBinding(\.directionGuideOpacity), range: 0.05...1, suffix: "", precision: 2)
                        SliderRow(title: "线宽", value: hudBinding(\.directionGuideLineWidth), range: 0.2...5, suffix: "px")
                        SliderRow(title: "箭头大小", value: hudBinding(\.directionGuideArrowSize), range: 2...24, suffix: "px")
                        SliderRow(title: "字体大小", value: hudBinding(\.directionGuideFontSize), range: 3...18, suffix: "px")
                    }
                    .padding(4)
                }

                GroupBox("颜色") {
                    VStack(alignment: .leading, spacing: 14) {
                        ColorPresetPicker(title: "高亮颜色", selection: hudBinding(\.highlightedColor))
                        ColorPresetPicker(title: "普通线条", selection: hudBinding(\.normalLineColor))
                    }
                    .padding(4)
                }
            }
            .padding(24)
        }
    }

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { value in
                store.updateSettings { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func hudBinding<Value>(_ keyPath: WritableKeyPath<HUDSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings.hudStyle[keyPath: keyPath] },
            set: { value in
                store.updateSettings { $0.hudStyle[keyPath: keyPath] = value }
            }
        )
    }
}

private struct HUDPreview: View {
    let style: HUDSettings

    var body: some View {
        GeometryReader { proxy in
            let points = previewPoints(in: proxy.size)
            let snapshot = GestureHUDSnapshot(
                isVisible: true,
                points: points,
                timedPoints: previewTimedPoints(points),
                screenFrame: CGRect(origin: .zero, size: proxy.size),
                directions: [.east, .southEast, .south],
                currentDirection: .southEast,
                style: style,
                message: "识别中",
                matchedAction: "示例动作",
                isError: false,
                isCancelled: false
            )

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.8))
                HUDOverlay(snapshot: snapshot)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func previewPoints(in size: CGSize) -> [CGPoint] {
        [
            CGPoint(x: size.width * 0.24, y: size.height * 0.46),
            CGPoint(x: size.width * 0.36, y: size.height * 0.46),
            CGPoint(x: size.width * 0.47, y: size.height * 0.58),
            CGPoint(x: size.width * 0.57, y: size.height * 0.70)
        ]
    }

    private func previewTimedPoints(_ points: [CGPoint]) -> [TimedGesturePoint] {
        let now = ProcessInfo.processInfo.systemUptime
        return points.enumerated().map { index, point in
            TimedGesturePoint(point: point, timestamp: now - Double(points.count - 1 - index) * 0.12)
        }
    }
}

private struct ColorPresetPicker: View {
    let title: String
    @Binding var selection: HUDColorPreset

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 110, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(HUDColorPreset.allCases) { preset in
                    Button {
                        selection = preset
                    } label: {
                        Circle()
                            .fill(preset.color)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(selection == preset ? Color.primary : Color.secondary.opacity(0.35), lineWidth: selection == preset ? 2 : 1)
                            )
                            .overlay {
                                if selection == preset {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(preset == .white ? .black : .white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(preset.title)
                }
            }
        }
    }
}

private struct GeneralSettingsPage: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var permissions: PermissionMonitor
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var gestureEngine: GestureEngine
    @EnvironmentObject private var actionExecutor: ActionExecutor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("通用设置")
                    .font(.largeTitle.bold())

                GroupBox("权限") {
                    HStack {
                        Label(
                            permissions.accessibilityGranted ? "辅助功能权限已开启" : "辅助功能权限未开启",
                            systemImage: permissions.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(permissions.accessibilityGranted ? .green : .orange)
                        Spacer()
                        Button("打开授权") {
                            permissions.requestAccessibilityPermission()
                        }
                    }
                    .padding(4)
                }
                .frame(maxWidth: .infinity)

                GroupBox("手势") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("启用全局手势", isOn: settingsBinding(\.gesturesEnabled))
                        SliderRow(title: "触发阈值", value: settingsBinding(\.movementThreshold), range: 6...40, suffix: "px")
                        SliderRow(title: "方向最小距离", value: settingsBinding(\.segmentMinDistance), range: 8...60, suffix: "px")
                        GestureThresholdPreview(
                            movementThreshold: store.settings.movementThreshold,
                            segmentMinDistance: store.settings.segmentMinDistance
                        )
                    }
                    .padding(4)
                }
                .frame(maxWidth: .infinity)

                GroupBox("系统") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("登录时启动", isOn: launchAtLoginBinding)
                        Toggle("在 Dock 中显示图标", isOn: settingsBinding(\.showDockIcon))
                        Text("Dock 图标设置重启 App 后最稳定。当前 MVP 默认显示 Dock 图标。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .frame(maxWidth: .infinity)

                GroupBox("默认模板") {
                    HStack {
                        Text("恢复默认模板会替换现有默认模板，保留你的自定义规则。")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认模板") {
                            store.restoreDefaultTemplates()
                        }
                    }
                    .padding(4)
                }
                .frame(maxWidth: .infinity)

                GroupBox("运行状态") {
                    VStack(alignment: .leading, spacing: 8) {
                        StatusLine("监听器", value: gestureEngine.isRunning ? "运行中" : "未运行")
                        StatusLine("动作执行", value: actionStateTitle)
                        if let error = store.lastError {
                            StatusLine("配置保存", value: error)
                        }
                    }
                    .padding(4)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 32)
            .padding(.trailing, 44)
            .padding(.vertical, 32)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { appEnvironment.launchAtLoginEnabled },
            set: { enabled in
                appEnvironment.setLaunchAtLogin(enabled)
                store.updateSettings { $0.launchAtLogin = enabled }
            }
        )
    }

    private var actionStateTitle: String {
        switch actionExecutor.state {
        case .idle: "空闲"
        case .running(let title): "执行中：\(title)"
        case .succeeded(let title): "完成：\(title)"
        case .failed(let message): "失败：\(message)"
        }
    }

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { value in
                store.updateSettings { $0[keyPath: keyPath] = value }
            }
        )
    }
}

private struct GestureThresholdPreview: View {
    let movementThreshold: Double
    let segmentMinDistance: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("阈值预览", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("触发后每段方向至少移动 \(segmentMinDistance.formatted(.number.precision(.fractionLength(1)))) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                Canvas { context, size in
                    drawPreview(in: size, context: &context)
                }
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.secondary.opacity(0.14))
                )
            }
            .frame(height: 104)
        }
        .padding(.top, 2)
    }

    private func drawPreview(in size: CGSize, context: inout GraphicsContext) {
        let start = CGPoint(x: 52, y: size.height - 34)
        let scale = max(1.15, min(2.1, (size.width - 120) / 92))
        let triggerRadius = min(34, max(10, movementThreshold * scale * 0.42))
        let segmentLength = min(size.width - 128, max(42, segmentMinDistance * scale))
        let triggerEnd = CGPoint(x: start.x + triggerRadius, y: start.y)
        let segmentEnd = CGPoint(x: triggerEnd.x + segmentLength, y: max(24, triggerEnd.y - segmentLength * 0.36))

        var triggerCircle = Path()
        triggerCircle.addEllipse(in: CGRect(
            x: start.x - triggerRadius,
            y: start.y - triggerRadius,
            width: triggerRadius * 2,
            height: triggerRadius * 2
        ))
        context.stroke(triggerCircle, with: .color(.blue.opacity(0.28)), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
        context.fill(triggerCircle, with: .color(.blue.opacity(0.06)))

        var path = Path()
        path.move(to: start)
        path.addLine(to: triggerEnd)
        path.addLine(to: segmentEnd)
        context.stroke(path, with: .color(.blue), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

        context.fill(Path(ellipseIn: CGRect(x: start.x - 5, y: start.y - 5, width: 10, height: 10)), with: .color(.primary.opacity(0.8)))
        context.fill(Path(ellipseIn: CGRect(x: triggerEnd.x - 4, y: triggerEnd.y - 4, width: 8, height: 8)), with: .color(.blue))
        context.fill(Path(ellipseIn: CGRect(x: segmentEnd.x - 5, y: segmentEnd.y - 5, width: 10, height: 10)), with: .color(.green))

        drawLabel("触发阈值", at: CGPoint(x: start.x, y: max(16, start.y - triggerRadius - 12)), context: &context, color: .blue)
        drawLabel("方向最小距离", at: CGPoint(x: (triggerEnd.x + segmentEnd.x) / 2, y: min(size.height - 16, (triggerEnd.y + segmentEnd.y) / 2 + 24)), context: &context, color: .green)
    }

    private func drawLabel(_ title: String, at point: CGPoint, context: inout GraphicsContext, color: Color) {
        let text = Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
        context.draw(text, at: point, anchor: .center)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    var precision: Int = 1

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 110, alignment: .leading)
            Slider(value: $value, in: range)
            Text("\(value.formatted(.number.precision(.fractionLength(precision)))) \(suffix)")
                .font(.caption.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
        }
    }
}

private struct StatusLine: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}

private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }
}

private struct EmptySelectionView: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
        .environmentObject(ConfigurationStore())
        .environmentObject(PermissionMonitor())
        .environmentObject(AppEnvironment())
        .environmentObject(GestureEngine())
        .environmentObject(ActionExecutor())
        .environmentObject(RangeSelectionCoordinator())
}
