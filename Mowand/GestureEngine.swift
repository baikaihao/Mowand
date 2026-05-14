import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation
import SwiftUI

struct GestureHUDSnapshot: Equatable, Identifiable {
    var id: UUID = UUID()
    var isVisible: Bool = false
    var points: [CGPoint] = []
    var timedPoints: [TimedGesturePoint] = []
    var screenFrame: CGRect?
    var directions: [GestureDirection] = []
    var currentDirection: GestureDirection?
    var style: HUDSettings = HUDSettings()
    var message: String = ""
    var matchedAction: String?
    var isError: Bool = false
    var isCancelled: Bool = false
    var fadeStartedAt: Date?
    var fadeDuration: TimeInterval = 0.15
}

struct GestureHUDPresentation: Equatable {
    var snapshots: [GestureHUDSnapshot] = []

    var isVisible: Bool {
        snapshots.contains(where: \.isVisible)
    }

    var screenFrame: CGRect? {
        snapshots.last(where: { $0.screenFrame != nil })?.screenFrame
    }
}

struct GestureTrajectorySnapshot: Equatable, Identifiable {
    var id: UUID
    var isVisible: Bool
    var points: [CGPoint]
    var screenFrame: CGRect?
    var style: HUDSettings
    var isError: Bool = false
    var isCancelled: Bool = false
    var fadeStartedAt: Date?
    var fadeDuration: TimeInterval = 0.15
}

struct GestureTrajectoryPresentation: Equatable {
    var snapshots: [GestureTrajectorySnapshot] = []

    var isVisible: Bool {
        snapshots.contains(where: \.isVisible)
    }

    var screenFrame: CGRect? {
        snapshots.last(where: { $0.screenFrame != nil })?.screenFrame
    }
}

struct TimedGesturePoint: Equatable {
    var point: CGPoint
    var timestamp: TimeInterval
}

@MainActor
final class GestureEngine: ObservableObject {
    private static let replayEventMarker: Int64 = 0x4D6F77616E64
    private static let defaultHUDDismissDelay: TimeInterval = 0.9
    private static let defaultHUDFadeDuration: TimeInterval = 0.15
    private static let maxSessionPoints = 4096
    nonisolated private static let maxSessionDirections = 128
    private static let maxHUDPoints = 360
    private static let hudPointCompactionThreshold = 420
    nonisolated private static let maxRecognitionPoints = 720
    nonisolated private static let hudPointMinDistance = 1.25
    nonisolated private static let minPolylineEpsilon = 3.0
    nonisolated private static let maxPolylineEpsilon = 10.0
    nonisolated private static let recognitionRefreshInterval: TimeInterval = 0.16
    private static let hudRefreshInterval: TimeInterval = 1.0 / 24.0
    private static let trajectoryRefreshInterval: TimeInterval = 1.0 / 60.0

    @Published private(set) var isRunning = false

    var hudPublisher: AnyPublisher<GestureHUDPresentation, Never> {
        hudSubject.eraseToAnyPublisher()
    }

    var trajectoryPublisher: AnyPublisher<GestureTrajectoryPresentation, Never> {
        trajectorySubject.eraseToAnyPublisher()
    }

    private var hud = GestureHUDPresentation()
    private var trajectory = GestureTrajectoryPresentation()
    private let hudSubject = CurrentValueSubject<GestureHUDPresentation, Never>(GestureHUDPresentation())
    private let trajectorySubject = CurrentValueSubject<GestureTrajectoryPresentation, Never>(GestureTrajectoryPresentation())
    private weak var store: ConfigurationStore?
    private weak var appEnvironment: AppEnvironment?
    private weak var executor: ActionExecutor?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var session = GestureSession()
    private var hudHideTasks: [UUID: Task<Void, Never>] = [:]
    private var recognitionTask: Task<Void, Never>?
    private var lastHUDUpdateTime: TimeInterval = 0
    private var lastTrajectoryUpdateTime: TimeInterval = 0
    private var replayedMouseEventsRemaining: [Int64: Int] = [:]

    func configure(store: ConfigurationStore, appEnvironment: AppEnvironment, executor: ActionExecutor) {
        self.store = store
        self.appEnvironment = appEnvironment
        self.executor = executor
    }

    func start() {
        guard tap == nil else { return }
        let mask =
            (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<GestureEngine>.fromOpaque(refcon).takeUnretainedValue()
            return engine.handle(proxy: proxy, type: type, event: event)
        }

        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            isRunning = false
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    func stop() {
        hudHideTasks.values.forEach { $0.cancel() }
        hudHideTasks.removeAll()
        recognitionTask?.cancel()
        recognitionTask = nil
        lastHUDUpdateTime = 0
        lastTrajectoryUpdateTime = 0
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        session = GestureSession()
        setHUD(GestureHUDPresentation())
        setTrajectory(GestureTrajectoryPresentation())
        isRunning = false
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.replayEventMarker {
            return Unmanaged.passUnretained(event)
        }

        if let buttonNumber = replayButtonNumber(for: type, event: event),
           let remaining = replayedMouseEventsRemaining[buttonNumber],
           remaining > 0 {
            if remaining == 1 {
                replayedMouseEventsRemaining[buttonNumber] = nil
            } else {
                replayedMouseEventsRemaining[buttonNumber] = remaining - 1
            }
            return Unmanaged.passUnretained(event)
        }

        guard let store, store.settings.gesturesEnabled else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == kVK_Escape {
            if session.isActive {
                cancelSession(message: "已取消")
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard let button = button(for: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .rightMouseDown, .otherMouseDown:
            let screenFrame = screenFrame(containing: event.location)
            guard store.hasEligibleRules(
                button: button,
                modifiers: ModifierFlags(),
                location: event.location,
                screenFrame: screenFrame,
                frontmostApplication: appEnvironment?.frontmostApplication
            ) else {
                return Unmanaged.passUnretained(event)
            }
            beginSession(at: event.location, button: button, screenFrame: screenFrame)
            return nil
        case .rightMouseDragged, .otherMouseDragged:
            guard session.isActive, button == session.button else {
                return Unmanaged.passUnretained(event)
            }
            updateSession(at: event.location)
            return nil
        case .rightMouseUp, .otherMouseUp:
            guard session.isActive, button == session.button else {
                return Unmanaged.passUnretained(event)
            }
            return endSession(event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func beginSession(
        at location: CGPoint,
        button: MouseTriggerButton,
        screenFrame: CGRect
    ) {
        recognitionTask?.cancel()
        recognitionTask = nil
        lastHUDUpdateTime = 0
        lastTrajectoryUpdateTime = 0
        let templateCandidates = store?.templateCandidates(
            button: button,
            modifiers: ModifierFlags(),
            location: location,
            screenFrame: screenFrame,
            frontmostApplication: appEnvironment?.frontmostApplication
        ) ?? []
        session = GestureSession(
            id: UUID(),
            isActive: true,
            hasExceededThreshold: false,
            button: button,
            screenFrame: screenFrame,
            startLocation: location,
            points: [location],
            timedPoints: [TimedGesturePoint(point: location, timestamp: eventTimestamp())],
            hudPoints: [location],
            simplifiedPoints: [location],
            directions: [],
            templateCandidates: templateCandidates,
            hasPotentialMatch: true
        )
    }

    private func updateSession(at location: CGPoint) {
        guard session.isActive, let store else { return }
        recordMovement(to: location, store: store)
        guard session.hasExceededThreshold else { return }
        updateTrajectoryFromSession(force: false)
        updateHUDFromCachedRecognition(force: false)
        scheduleRecognitionRefresh()
    }

    private func recordMovement(to location: CGPoint, store: ConfigurationStore) {
        let distanceFromStart = hypot(location.x - session.startLocation.x, location.y - session.startLocation.y)
        if !session.hasExceededThreshold, distanceFromStart >= store.settings.movementThreshold {
            session.hasExceededThreshold = true
        }

        guard session.hasExceededThreshold else { return }

        if let lastPoint = session.points.last {
            let distanceFromLastPoint = hypot(location.x - lastPoint.x, location.y - lastPoint.y)
            if distanceFromLastPoint >= 0.5 {
                appendSessionPoint(location)
            }
        } else {
            appendSessionPoint(location)
        }
    }

    private func appendSessionPoint(_ location: CGPoint) {
        session.points.append(location)
        session.timedPoints.append(TimedGesturePoint(point: location, timestamp: eventTimestamp()))
        appendHUDPoint(location)

        let overflow = session.points.count - Self.maxSessionPoints
        guard overflow > 0 else { return }
        session.points.removeFirst(overflow)
        session.timedPoints.removeFirst(min(overflow, session.timedPoints.count))
    }

    private func appendHUDPoint(_ location: CGPoint) {
        if let lastPoint = session.hudPoints.last {
            let distance = hypot(location.x - lastPoint.x, location.y - lastPoint.y)
            guard distance >= Self.hudPointMinDistance else { return }
        }

        session.hudPoints.append(location)
        guard session.hudPoints.count > Self.hudPointCompactionThreshold else { return }
        session.hudPoints = Self.downsample(points: session.hudPoints, maxCount: Self.maxHUDPoints)
    }

    private func endSession(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard session.isActive else { return Unmanaged.passUnretained(event) }

        recognitionTask?.cancel()
        recognitionTask = nil

        defer {
            session = GestureSession()
        }

        guard let store else { return nil }
        recordMovement(to: event.location, store: store)

        guard session.hasExceededThreshold else {
            replayClick(button: session.button, at: session.startLocation)
            hideHUDAfterDelay(id: session.id)
            return nil
        }

        refreshRecognition(minimumDistance: store.settings.segmentMinDistance, isRealtime: false)
        updateTrajectoryFromSession(force: true, isError: session.match == nil)
        updateHUDFromCachedRecognition(force: true)
        let match = session.match
        let recognizedDirections = match?.rule.directions ?? session.directions

        if let match {
            updateHUDSnapshot(id: session.id) { snapshot in
                snapshot.matchedAction = match.rule.actionTitle
                snapshot.message = match.rule.name
                snapshot.directions = recognizedDirections
                snapshot.currentDirection = recognizedDirections.last ?? snapshot.currentDirection
            }
            Task { [weak executor] in
                await executor?.execute(rule: match.rule)
            }
        } else {
            upsertHUDSnapshot(GestureHUDSnapshot(
                id: session.id,
                isVisible: store.settings.hudEnabled,
                points: hudAnchorPoints(),
                timedPoints: [],
                screenFrame: session.screenFrame,
                directions: recognizedDirections,
                currentDirection: recognizedDirections.last ?? currentDirection(),
                style: store.settings.hudStyle,
                message: store.matchFailureMessage(
                    directions: recognizedDirections,
                    button: session.button,
                    modifiers: ModifierFlags(),
                    location: session.startLocation,
                    screenFrame: session.screenFrame,
                    frontmostApplication: appEnvironment?.frontmostApplication
                ),
                matchedAction: recognizedDirections.map(\.title).joined(separator: " -> "),
                isError: true
            ))
        }
        hideHUDAfterDelay(id: session.id)
        return nil
    }

    private func cancelSession(message: String) {
        recognitionTask?.cancel()
        recognitionTask = nil
        let cancelledSession = session
        if let store, store.settings.hudEnabled {
            updateTrajectory(from: cancelledSession, style: store.settings.hudStyle, isCancelled: true)
            upsertHUDSnapshot(GestureHUDSnapshot(
                id: cancelledSession.id,
                isVisible: true,
                points: hudAnchorPoints(from: cancelledSession),
                timedPoints: [],
                screenFrame: cancelledSession.screenFrame,
                directions: cancelledSession.directions,
                currentDirection: currentDirection(),
                style: store.settings.hudStyle,
                message: message,
                matchedAction: nil,
                isError: false,
                isCancelled: true
            ))
        }
        session = GestureSession()
        hideHUDAfterDelay(id: cancelledSession.id)
    }

    private func updateHUDFromCachedRecognition(force: Bool = true) {
        guard let store, store.settings.hudEnabled, !store.settings.hudOnlyForErrors else { return }
        let now = eventTimestamp()
        guard force || now - lastHUDUpdateTime >= Self.hudRefreshInterval else { return }
        lastHUDUpdateTime = now

        let match = session.match
        let recognizedDirections = match?.rule.directions ?? session.directions
        let isPotentialMatch = match == nil && session.hasPotentialMatch
        let message: String
        let matchedAction: String?

        if let match {
            message = match.rule.name
            matchedAction = match.rule.actionTitle
        } else {
            message = isPotentialMatch ? "识别中" : "未分配手势"
            matchedAction = nil
        }

        upsertHUDSnapshot(GestureHUDSnapshot(
            id: session.id,
            isVisible: true,
            points: hudAnchorPoints(),
            timedPoints: [],
            screenFrame: session.screenFrame,
            directions: recognizedDirections,
            currentDirection: recognizedDirections.last ?? currentDirection(),
            style: store.settings.hudStyle,
            message: message,
            matchedAction: matchedAction,
            isError: false,
            isCancelled: false
        ))
    }

    private func scheduleRecognitionRefresh() {
        guard recognitionTask == nil else { return }
        recognitionTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(Self.recognitionRefreshInterval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard let request = self.makeRecognitionRequest() else {
                self.recognitionTask = nil
                return
            }

            let result = await Task.detached(priority: .background) {
                Self.recognitionResult(for: request, isRealtime: true)
            }.value
            guard !Task.isCancelled else { return }

            self.recognitionTask = nil
            guard self.session.id == request.sessionID,
                  self.session.isActive,
                  self.session.hasExceededThreshold else {
                return
            }

            self.applyRecognitionResult(result)
            self.updateHUDFromCachedRecognition(force: false)
        }
    }

    private func makeRecognitionRequest() -> GestureRecognitionRequest? {
        guard let store, session.isActive, session.hasExceededThreshold else { return nil }
        return GestureRecognitionRequest(
            sessionID: session.id,
            points: Self.recognitionPoints(from: session.points),
            minimumDistance: store.settings.segmentMinDistance,
            candidates: session.templateCandidates
        )
    }

    private func applyRecognitionResult(_ result: GestureRecognitionResult) {
        session.simplifiedPoints = result.simplifiedPoints
        session.directions = result.directions

        guard let store else {
            session.match = nil
            session.hasPotentialMatch = true
            return
        }

        if let directionMatch = store.match(
            directions: result.directions,
            button: session.button,
            modifiers: ModifierFlags(),
            location: session.startLocation,
            screenFrame: session.screenFrame,
            frontmostApplication: appEnvironment?.frontmostApplication
        ) {
            session.match = directionMatch
            session.hasPotentialMatch = false
            return
        }

        if let templateMatch = result.templateMatch,
           let match = store.match(
            ruleID: templateMatch.ruleID,
            isApplicationSpecific: templateMatch.isApplicationSpecific,
            recognition: .template
           ) {
            session.match = match
            session.hasPotentialMatch = false
            return
        }

        session.match = nil
        session.hasPotentialMatch = store.hasPotentialMatch(
            directions: session.directions,
            button: session.button,
            modifiers: ModifierFlags(),
            location: session.startLocation,
            screenFrame: session.screenFrame,
            frontmostApplication: appEnvironment?.frontmostApplication
        )
    }

    private func hideHUDAfterDelay(id: UUID) {
        guard hud.snapshots.contains(where: { $0.id == id }) else { return }
        hudHideTasks[id]?.cancel()
        hudHideTasks[id] = Task { [weak self] in
            do {
                let dismissDelay = await MainActor.run {
                    self?.store?.settings.hudDismissDelay ?? Self.defaultHUDDismissDelay
                }
                try await Task.sleep(nanoseconds: Self.nanoseconds(dismissDelay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let fadeDuration = await MainActor.run {
                self?.store?.settings.hudFadeDuration ?? Self.defaultHUDFadeDuration
            }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self?.markHUDSnapshotFading(id: id, duration: fadeDuration)
            }
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(fadeDuration))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self?.removeHUDSnapshot(id: id)
                self?.hudHideTasks[id] = nil
            }
        }
    }

    private func upsertHUDSnapshot(_ snapshot: GestureHUDSnapshot) {
        var presentation = hud
        if let index = presentation.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
            presentation.snapshots[index] = snapshot
        } else {
            presentation.snapshots.append(snapshot)
        }

        if presentation.snapshots.count > 6 {
            let overflow = presentation.snapshots.count - 6
            let removedIDs = presentation.snapshots.prefix(overflow).map(\.id)
            presentation.snapshots.removeFirst(overflow)
            for id in removedIDs {
                hudHideTasks[id]?.cancel()
                hudHideTasks[id] = nil
            }
        }
        setHUD(presentation)
    }

    private func updateTrajectoryFromSession(force: Bool = true, isError: Bool = false, isCancelled: Bool = false) {
        guard let store,
              store.settings.hudEnabled,
              !store.settings.hudOnlyForErrors,
              store.settings.hudStyle.showTrajectory else {
            return
        }
        let now = eventTimestamp()
        guard force || now - lastTrajectoryUpdateTime >= Self.trajectoryRefreshInterval else { return }
        lastTrajectoryUpdateTime = now
        updateTrajectory(from: session, style: store.settings.hudStyle, isError: isError, isCancelled: isCancelled)
    }

    private func updateTrajectory(
        from session: GestureSession,
        style: HUDSettings,
        isError: Bool = false,
        isCancelled: Bool = false
    ) {
        guard style.showTrajectory else { return }
        upsertTrajectorySnapshot(GestureTrajectorySnapshot(
            id: session.id,
            isVisible: true,
            points: hudPoints(from: session),
            screenFrame: session.screenFrame,
            style: style,
            isError: isError,
            isCancelled: isCancelled
        ))
    }

    private func upsertTrajectorySnapshot(_ snapshot: GestureTrajectorySnapshot) {
        var presentation = trajectory
        if let index = presentation.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
            presentation.snapshots[index] = snapshot
        } else {
            presentation.snapshots.append(snapshot)
        }

        if presentation.snapshots.count > 6 {
            presentation.snapshots.removeFirst(presentation.snapshots.count - 6)
        }
        setTrajectory(presentation)
    }

    private func updateHUDSnapshot(id: UUID, update: (inout GestureHUDSnapshot) -> Void) {
        var presentation = hud
        guard let index = presentation.snapshots.firstIndex(where: { $0.id == id }) else { return }
        update(&presentation.snapshots[index])
        setHUD(presentation)
    }

    private func markHUDSnapshotFading(id: UUID, duration: TimeInterval) {
        updateHUDSnapshot(id: id) { snapshot in
            snapshot.fadeStartedAt = Date()
            snapshot.fadeDuration = duration
        }
        markTrajectorySnapshotFading(id: id, duration: duration)
    }

    private func removeHUDSnapshot(id: UUID) {
        var presentation = hud
        presentation.snapshots.removeAll { $0.id == id }
        setHUD(presentation)
        removeTrajectorySnapshot(id: id)
    }

    private func markTrajectorySnapshotFading(id: UUID, duration: TimeInterval) {
        var presentation = trajectory
        guard let index = presentation.snapshots.firstIndex(where: { $0.id == id }) else { return }
        presentation.snapshots[index].fadeStartedAt = Date()
        presentation.snapshots[index].fadeDuration = duration
        setTrajectory(presentation)
    }

    private func removeTrajectorySnapshot(id: UUID) {
        var presentation = trajectory
        presentation.snapshots.removeAll { $0.id == id }
        setTrajectory(presentation)
    }

    private func setHUD(_ presentation: GestureHUDPresentation) {
        hud = presentation
        hudSubject.send(presentation)
    }

    private func setTrajectory(_ presentation: GestureTrajectoryPresentation) {
        trajectory = presentation
        trajectorySubject.send(presentation)
    }

    nonisolated private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    private func currentDirection() -> GestureDirection? {
        guard session.hasExceededThreshold else { return nil }
        let recentPoints = session.points.suffix(6)
        if let first = recentPoints.first,
           let current = recentPoints.last,
           let direction = GestureDirection.from(
            delta: CGSize(width: current.x - first.x, height: current.y - first.y)
           ) {
            return direction
        }
        if session.simplifiedPoints.count >= 2,
           let previous = session.simplifiedPoints.dropLast().last,
           let current = session.simplifiedPoints.last,
           let direction = GestureDirection.from(
            delta: CGSize(width: current.x - previous.x, height: current.y - previous.y)
           ) {
            return direction
        }
        guard let current = session.points.last else { return session.directions.last }
        return GestureDirection.from(
            delta: CGSize(width: current.x - session.startLocation.x, height: current.y - session.startLocation.y)
        ) ?? session.directions.last
    }

    nonisolated private static func polylineEpsilon(for minimumDistance: Double) -> Double {
        min(maxPolylineEpsilon, max(minPolylineEpsilon, minimumDistance * 0.3))
    }

    private func refreshRecognition(minimumDistance: Double, isRealtime: Bool) {
        applyRecognitionResult(Self.recognitionResult(
            for: GestureRecognitionRequest(
                sessionID: session.id,
                points: Self.recognitionPoints(from: session.points),
                minimumDistance: minimumDistance,
                candidates: session.templateCandidates
            ),
            isRealtime: isRealtime
        ))
    }

    nonisolated private static func recognitionResult(for request: GestureRecognitionRequest, isRealtime: Bool) -> GestureRecognitionResult {
        let epsilon = polylineEpsilon(for: request.minimumDistance)
        let simplifiedPoints = simplifiedPolyline(points: request.points, epsilon: epsilon)
        let segmentCount = max(1, simplifiedPoints.count - 1)
        let gestureVector = GestureTemplateRecognizer.vector(forStroke: request.points)
        let directions = gestureVector.flatMap {
            GestureTemplateRecognizer.bestDirections(
                gestureVector: $0,
                segmentCount: segmentCount,
                isRealtime: isRealtime
            )
        } ?? directions(from: simplifiedPoints, minimumDistance: request.minimumDistance)
        let templateMatch = gestureVector.flatMap {
            GestureTemplateRecognizer.bestMatch(gestureVector: $0, candidates: request.candidates)
        }
        return GestureRecognitionResult(
            sessionID: request.sessionID,
            simplifiedPoints: simplifiedPoints,
            directions: directions,
            templateMatch: templateMatch.map {
                GestureTemplateMatch(ruleID: $0.ruleID, isApplicationSpecific: $0.isApplicationSpecific)
            }
        )
    }

    private func hudPoints() -> [CGPoint] {
        hudPoints(from: session)
    }

    private func hudPoints(from session: GestureSession) -> [CGPoint] {
        if !session.hudPoints.isEmpty {
            return session.hudPoints
        }
        return Self.downsample(points: session.points, maxCount: Self.maxHUDPoints)
    }

    private func hudAnchorPoints() -> [CGPoint] {
        hudAnchorPoints(from: session)
    }

    private func hudAnchorPoints(from session: GestureSession) -> [CGPoint] {
        Self.anchorPoints(from: hudPoints(from: session))
    }

    nonisolated private static func anchorPoints(from points: [CGPoint]) -> [CGPoint] {
        guard let first = points.first else { return [] }
        guard points.count > 2 else { return points }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        return [
            CGPoint(x: minX, y: minY),
            CGPoint(x: maxX, y: maxY),
            points[points.index(before: points.endIndex)]
        ]
    }

    nonisolated private static func recognitionPoints(from points: [CGPoint]) -> [CGPoint] {
        downsample(points: points, maxCount: maxRecognitionPoints)
    }

    nonisolated private static func downsample(points: [CGPoint], maxCount: Int) -> [CGPoint] {
        guard points.count > maxCount, maxCount >= 2 else { return points }
        let stride = Double(points.count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { index in
            points[min(points.count - 1, Int((Double(index) * stride).rounded()))]
        }
    }

    nonisolated private static func simplifiedPolyline(points: [CGPoint], epsilon: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }

        var keptIndices = Set<Int>()
        keptIndices.insert(points.startIndex)
        keptIndices.insert(points.index(before: points.endIndex))

        var ranges = [(points.startIndex, points.index(before: points.endIndex))]
        while let (startIndex, endIndex) = ranges.popLast() {
            guard endIndex > startIndex + 1 else { continue }

            var farthestIndex = startIndex
            var farthestDistance = 0.0
            for index in (startIndex + 1)..<endIndex {
                let distance = perpendicularDistance(
                    from: points[index],
                    toLineStart: points[startIndex],
                    lineEnd: points[endIndex]
                )
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthestIndex = index
                }
            }

            guard farthestDistance > epsilon else { continue }
            keptIndices.insert(farthestIndex)
            ranges.append((startIndex, farthestIndex))
            ranges.append((farthestIndex, endIndex))
        }

        return keptIndices.sorted().map { points[$0] }
    }

    nonisolated private static func perpendicularDistance(from point: CGPoint, toLineStart lineStart: CGPoint, lineEnd: CGPoint) -> Double {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - lineStart.x, point.y - lineStart.y)
        }

        let numerator = abs(dy * point.x - dx * point.y + lineEnd.x * lineStart.y - lineEnd.y * lineStart.x)
        return numerator / sqrt(lengthSquared)
    }

    nonisolated private static func directions(from points: [CGPoint], minimumDistance: Double) -> [GestureDirection] {
        guard points.count >= 2 else { return [] }

        var directions: [GestureDirection] = []
        let minimumSegmentLength = max(1, minimumDistance)
        for index in points.indices.dropLast() {
            let start = points[index]
            let end = points[index + 1]
            let delta = CGSize(width: end.x - start.x, height: end.y - start.y)
            let distance = hypot(delta.width, delta.height)
            guard distance >= minimumSegmentLength,
                  let direction = GestureDirection.from(delta: delta) else { continue }
            appendDirection(direction, to: &directions)
            let overflow = directions.count - maxSessionDirections
            if overflow > 0 {
                directions.removeFirst(overflow)
            }
        }
        return directions
    }

    nonisolated private static func appendDirection(_ direction: GestureDirection, to directions: inout [GestureDirection]) {
        if directions.last == direction { return }

        if directions.count >= 2,
           let previous = directions.dropLast().last,
           let bridge = directions.last,
           bridge.isDiagonalBridge(from: previous, to: direction) {
            directions.removeLast()
        }

        if directions.last != direction {
            directions.append(direction)
        }
    }

    private func replayClick(button: MouseTriggerButton, at location: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let mouseButton = cgMouseButton(for: button)
        let down = CGEvent(mouseEventSource: source, mouseType: mouseDownType(for: button), mouseCursorPosition: location, mouseButton: mouseButton)
        let up = CGEvent(mouseEventSource: source, mouseType: mouseUpType(for: button), mouseCursorPosition: location, mouseButton: mouseButton)
        down?.setIntegerValueField(.mouseEventButtonNumber, value: button.buttonNumber)
        up?.setIntegerValueField(.mouseEventButtonNumber, value: button.buttonNumber)
        down?.setIntegerValueField(.eventSourceUserData, value: Self.replayEventMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: Self.replayEventMarker)
        replayedMouseEventsRemaining[button.buttonNumber, default: 0] += 2
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func cgMouseButton(for button: MouseTriggerButton) -> CGMouseButton {
        switch button {
        case .right: return .right
        case .middle: return .center
        case .auxiliary(let buttonNumber): return CGMouseButton(rawValue: UInt32(buttonNumber)) ?? .center
        }
    }

    private func mouseDownType(for button: MouseTriggerButton) -> CGEventType {
        switch button {
        case .right: return .rightMouseDown
        case .middle, .auxiliary: return .otherMouseDown
        }
    }

    private func mouseUpType(for button: MouseTriggerButton) -> CGEventType {
        switch button {
        case .right: return .rightMouseUp
        case .middle, .auxiliary: return .otherMouseUp
        }
    }

    private func replayButtonNumber(for type: CGEventType, event: CGEvent) -> Int64? {
        switch type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
            return MouseTriggerButton.right.buttonNumber
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            return event.getIntegerValueField(.mouseEventButtonNumber)
        default:
            return nil
        }
    }

    private func screenFrame(containing location: CGPoint) -> CGRect {
        NSScreen.screens.first(where: { $0.frame.contains(location) })?.frame
            ?? NSScreen.main?.frame
            ?? CGRect(origin: .zero, size: CGSize(width: CGDisplayPixelsWide(CGMainDisplayID()), height: CGDisplayPixelsHigh(CGMainDisplayID())))
    }

    private func eventTimestamp() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func button(for type: CGEventType, event: CGEvent) -> MouseTriggerButton? {
        switch type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
            return .right
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            guard buttonNumber > 1 else { return nil }
            if buttonNumber == MouseTriggerButton.middle.buttonNumber { return .middle }
            return .auxiliary(buttonNumber)
        default:
            return nil
        }
    }
}

private struct GestureSession {
    var id: UUID = UUID()
    var isActive: Bool = false
    var hasExceededThreshold: Bool = false
    var button: MouseTriggerButton = .right
    var screenFrame: CGRect = .zero
    var startLocation: CGPoint = .zero
    var points: [CGPoint] = []
    var timedPoints: [TimedGesturePoint] = []
    var hudPoints: [CGPoint] = []
    var simplifiedPoints: [CGPoint] = []
    var directions: [GestureDirection] = []
    var match: GestureMatch?
    var templateCandidates: [GestureTemplateCandidate] = []
    var hasPotentialMatch: Bool = true
}

private struct GestureRecognitionRequest: Sendable {
    var sessionID: UUID
    var points: [CGPoint]
    var minimumDistance: Double
    var candidates: [GestureTemplateCandidate]
}

private struct GestureRecognitionResult: Sendable {
    var sessionID: UUID
    var simplifiedPoints: [CGPoint]
    var directions: [GestureDirection]
    var templateMatch: GestureTemplateMatch?
}

private struct GestureTemplateMatch: Sendable {
    var ruleID: UUID
    var isApplicationSpecific: Bool
}
