import Combine
import CoreGraphics
import Foundation

@MainActor
final class ConfigurationStore: ObservableObject {
    @Published private(set) var configuration: MowandConfiguration
    @Published var lastError: String?

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        let resolvedFileURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedFileURL
        self.configuration = Self.load(from: resolvedFileURL)
        installDefaultTemplatesIfNeeded()
    }

    var settings: AppSettings { configuration.settings }
    var rules: [GestureRule] { configuration.rules }
    var excludedApplications: [AppIdentity] { configuration.excludedApplications }

    func updateSettings(_ transform: (inout AppSettings) -> Void) {
        transform(&configuration.settings)
        scheduleSave()
    }

    func replaceRules(_ rules: [GestureRule]) {
        configuration.rules = rules
        scheduleSave()
    }

    func upsertRule(_ rule: GestureRule) {
        var updatedRule = rule
        updatedRule.updatedAt = Date()
        if let index = configuration.rules.firstIndex(where: { $0.id == rule.id }) {
            configuration.rules[index] = updatedRule
        } else {
            configuration.rules.append(updatedRule)
        }
        scheduleSave()
    }

    func deleteRule(_ rule: GestureRule) {
        configuration.rules.removeAll { $0.id == rule.id }
        scheduleSave()
    }

    func restoreDefaultTemplates() {
        let defaultRules = DefaultTemplates.makeRules()
        let nonDefaultRules = configuration.rules.filter { !$0.isDefaultTemplate }
        configuration.rules = nonDefaultRules + defaultRules
        configuration.hasInstalledDefaultTemplates = true
        scheduleSave()
    }

    func installDefaultTemplatesIfNeeded() {
        guard !configuration.hasInstalledDefaultTemplates else { return }
        configuration.rules.append(contentsOf: DefaultTemplates.makeRules())
        configuration.hasInstalledDefaultTemplates = true
        scheduleSave(immediate: true)
    }

    func addExcludedApplication(_ app: AppIdentity) {
        guard !configuration.excludedApplications.contains(where: { $0.id == app.id }) else { return }
        configuration.excludedApplications.append(app)
        scheduleSave()
    }

    func removeExcludedApplication(_ app: AppIdentity) {
        configuration.excludedApplications.removeAll { $0.id == app.id }
        scheduleSave()
    }

    func match(
        directions: [GestureDirection],
        button: MouseTriggerButton,
        modifiers: ModifierFlags,
        location: CGPoint,
        screenFrame: CGRect,
        frontmostApplication: AppIdentity?
    ) -> GestureMatch? {
        guard let candidate = eligibleRuleCandidates(
            button: button,
            modifiers: modifiers,
            location: location,
            screenFrame: screenFrame,
            frontmostApplication: frontmostApplication
        ).first(where: { $0.rule.directions == directions }) else {
            return nil
        }

        return GestureMatch(
            rule: candidate.rule,
            isApplicationSpecific: candidate.isApplicationSpecific,
            recognition: .directionChain
        )
    }

    func templateMatch(
        points: [CGPoint],
        button: MouseTriggerButton,
        modifiers: ModifierFlags,
        location: CGPoint,
        screenFrame: CGRect,
        frontmostApplication: AppIdentity?
    ) -> GestureMatch? {
        let candidates = eligibleRuleCandidates(
            button: button,
            modifiers: modifiers,
            location: location,
            screenFrame: screenFrame,
            frontmostApplication: frontmostApplication
        ).filter { !$0.rule.directions.isEmpty }

        guard let candidate = GestureTemplateRecognizer.bestMatch(points: points, candidates: candidates) else {
            return nil
        }

        return GestureMatch(
            rule: candidate.rule,
            isApplicationSpecific: candidate.isApplicationSpecific,
            recognition: .template
        )
    }

    func templateCandidates(
        button: MouseTriggerButton,
        modifiers: ModifierFlags,
        location: CGPoint,
        screenFrame: CGRect,
        frontmostApplication: AppIdentity?
    ) -> [GestureTemplateCandidate] {
        eligibleRuleCandidates(
            button: button,
            modifiers: modifiers,
            location: location,
            screenFrame: screenFrame,
            frontmostApplication: frontmostApplication
        ).compactMap { candidate in
            guard !candidate.rule.directions.isEmpty else { return nil }
            let vectors = GestureTemplateRecognizer.templateVectors(for: candidate.rule)
            guard !vectors.isEmpty else { return nil }
            return GestureTemplateCandidate(
                ruleID: candidate.rule.id,
                isApplicationSpecific: candidate.isApplicationSpecific,
                templateVectors: vectors
            )
        }
    }

    func match(ruleID: UUID, isApplicationSpecific: Bool, recognition: GestureRecognitionKind) -> GestureMatch? {
        guard let rule = configuration.rules.first(where: { $0.id == ruleID && $0.isEnabled }) else {
            return nil
        }
        return GestureMatch(
            rule: rule,
            isApplicationSpecific: isApplicationSpecific,
            recognition: recognition
        )
    }

    func hasPotentialMatch(
        directions: [GestureDirection],
        button: MouseTriggerButton,
        modifiers: ModifierFlags,
        location: CGPoint,
        screenFrame: CGRect,
        frontmostApplication: AppIdentity?
    ) -> Bool {
        guard !directions.isEmpty else { return true }

        let enabledRules = configuration.rules.filter {
            $0.isEnabled
                && $0.triggerButton == button
                && $0.modifiers == modifiers
                && $0.directions.count > directions.count
                && $0.directions.starts(with: directions)
                && $0.region.contains(location: location, in: screenFrame)
        }

        if let frontmostApplication,
           enabledRules.contains(where: { rule in
               rule.scope.bundleIdentifier == frontmostApplication.bundleIdentifier
                   || (rule.scope.bundleIdentifier == nil && rule.scope.title == frontmostApplication.displayName)
           }) {
            return true
        }

        let isExcluded = frontmostApplication.map(isApplicationExcluded) ?? false
        guard !isExcluded else { return false }

        return enabledRules.contains(where: isGlobalRule)
    }

    func matchFailureMessage(
        directions: [GestureDirection],
        button: MouseTriggerButton,
        modifiers: ModifierFlags,
        location: CGPoint,
        screenFrame: CGRect,
        frontmostApplication: AppIdentity?
    ) -> String {
        guard !directions.isEmpty else { return "未识别到方向" }

        let directionRules = configuration.rules.filter { $0.directions == directions }
        guard !directionRules.isEmpty else { return "未分配手势" }

        let enabledDirectionRules = directionRules.filter(\.isEnabled)
        guard !enabledDirectionRules.isEmpty else { return "方向已分配，但规则未启用" }

        let triggerRules = enabledDirectionRules.filter {
            $0.triggerButton == button && $0.modifiers == modifiers
        }
        guard !triggerRules.isEmpty else { return "方向已分配，触发条件不一致" }

        let regionRules = triggerRules.filter {
            $0.region.contains(location: location, in: screenFrame)
        }
        guard !regionRules.isEmpty else { return "方向已分配，起点不在屏幕区域" }

        let isExcluded = frontmostApplication.map(isApplicationExcluded) ?? false
        if isExcluded, regionRules.contains(where: isGlobalRule) {
            return "当前 App 已排除"
        }

        return "方向已分配，不适用于当前 App"
    }

    func conflictingRules(for candidate: GestureRule) -> [GestureRule] {
        configuration.rules.filter { rule in
            rule.id != candidate.id
                && rule.isEnabled
                && candidate.isEnabled
                && rule.triggerButton == candidate.triggerButton
                && rule.modifiers == candidate.modifiers
                && rule.region == candidate.region
                && rule.scope == candidate.scope
                && rule.directions == candidate.directions
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try Self.save(configuration, to: fileURL)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func scheduleSave(immediate: Bool = false) {
        saveTask?.cancel()
        if immediate {
            saveNow()
            return
        }

        let snapshot = configuration
        let fileURL = fileURL
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            do {
                try Self.save(snapshot, to: fileURL)
                await MainActor.run { self.lastError = nil }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    private static func load(from fileURL: URL) -> MowandConfiguration {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var configuration = try decoder.decode(MowandConfiguration.self, from: data)
            if configuration.schemaVersion < MowandConfiguration.currentSchemaVersion {
                configuration.schemaVersion = MowandConfiguration.currentSchemaVersion
            }
            return configuration
        } catch {
            return .empty
        }
    }

    private static func save(_ configuration: MowandConfiguration, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(configuration)
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Mowand", isDirectory: true).appendingPathComponent("config.json")
    }

    private func isApplicationExcluded(_ app: AppIdentity) -> Bool {
        configuration.excludedApplications.contains { excluded in
            if let excludedBundle = excluded.bundleIdentifier, let appBundle = app.bundleIdentifier {
                return excludedBundle == appBundle
            }
            return excluded.path == app.path || excluded.displayName == app.displayName
        }
    }

    private func isGlobalRule(_ rule: GestureRule) -> Bool {
        if case .global = rule.scope { return true }
        return false
    }

    private func eligibleRuleCandidates(
        button: MouseTriggerButton,
        modifiers: ModifierFlags,
        location: CGPoint,
        screenFrame: CGRect,
        frontmostApplication: AppIdentity?
    ) -> [GestureRuleCandidate] {
        let triggerRules = configuration.rules.filter {
            $0.isEnabled
                && $0.triggerButton == button
                && $0.modifiers == modifiers
                && $0.region.contains(location: location, in: screenFrame)
        }

        let applicationRules: [GestureRuleCandidate]
        if let frontmostApplication {
            applicationRules = triggerRules.compactMap { rule in
                guard rule.matchesApplication(frontmostApplication) else { return nil }
                return GestureRuleCandidate(rule: rule, isApplicationSpecific: true)
            }
        } else {
            applicationRules = []
        }

        let isExcluded = frontmostApplication.map(isApplicationExcluded) ?? false
        let globalRules: [GestureRuleCandidate]
        if isExcluded {
            globalRules = []
        } else {
            globalRules = triggerRules.compactMap { rule in
                guard isGlobalRule(rule) else { return nil }
                return GestureRuleCandidate(rule: rule, isApplicationSpecific: false)
            }
        }

        return applicationRules + globalRules
    }
}

struct GestureRuleCandidate {
    var rule: GestureRule
    var isApplicationSpecific: Bool
}

struct GestureTemplateCandidate: Sendable {
    var ruleID: UUID
    var isApplicationSpecific: Bool
    var templateVectors: [[Double]]
}

private extension GestureRule {
    func matchesApplication(_ application: AppIdentity) -> Bool {
        switch scope {
        case .global:
            return false
        case .application(let identity):
            if let ruleBundle = identity.bundleIdentifier,
               let applicationBundle = application.bundleIdentifier {
                return ruleBundle == applicationBundle
            }
            return identity.path == application.path || identity.displayName == application.displayName
        }
    }
}

extension ScreenRegion {
    func contains(location: CGPoint, in screenFrame: CGRect) -> Bool {
        let rect = concreteRect(in: screenFrame)
        return rect.contains(location)
    }

    func concreteRect(in screenFrame: CGRect) -> CGRect {
        let normalized: NormalizedRect
        switch kind {
        case .full:
            normalized = .full
        case .leftHalf:
            normalized = NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf:
            normalized = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf:
            normalized = NormalizedRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf:
            normalized = NormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeftQuarter:
            normalized = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRightQuarter:
            normalized = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeftQuarter:
            normalized = NormalizedRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRightQuarter:
            normalized = NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .custom:
            normalized = customRect ?? .full
        }

        return CGRect(
            x: screenFrame.minX + screenFrame.width * normalized.x,
            y: screenFrame.minY + screenFrame.height * normalized.y,
            width: screenFrame.width * normalized.width,
            height: screenFrame.height * normalized.height
        )
    }
}
