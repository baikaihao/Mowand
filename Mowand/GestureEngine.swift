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
    private static let maxSessionDirections = 128

    @Published private(set) var hud = GestureHUDPresentation()
    @Published private(set) var isRunning = false

    private weak var store: ConfigurationStore?
    private weak var appEnvironment: AppEnvironment?
    private weak var executor: ActionExecutor?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var session = GestureSession()
    private var hudHideTasks: [UUID: Task<Void, Never>] = [:]
    private var replayedRightClickEventsRemaining = 0

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
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        session = GestureSession()
        hud = GestureHUDPresentation()
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

        if replayedRightClickEventsRemaining > 0, isRightClickReplayEvent(type) {
            replayedRightClickEventsRemaining -= 1
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

        guard let button = button(for: type, event: event),
              button == store.settings.triggerButton,
              ModifierFlags(cgFlags: event.flags) == store.settings.triggerModifiers else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .rightMouseDown, .otherMouseDown:
            beginSession(at: event.location, button: button)
            return nil
        case .rightMouseDragged, .otherMouseDragged:
            updateSession(at: event.location)
            return nil
        case .rightMouseUp, .otherMouseUp:
            return endSession(event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func beginSession(at location: CGPoint, button: MouseTriggerButton) {
        session = GestureSession(
            id: UUID(),
            isActive: true,
            hasExceededThreshold: false,
            button: button,
            screenFrame: screenFrame(containing: location),
            startLocation: location,
            lastEventLocation: location,
            points: [location],
            timedPoints: [TimedGesturePoint(point: location, timestamp: eventTimestamp())],
            directions: []
        )
    }

    private func updateSession(at location: CGPoint) {
        guard session.isActive, let store else { return }
        recordMovement(to: location, store: store)
        guard session.hasExceededThreshold else { return }
        updateHUD()
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

        ingestMovement(to: location, minimumDistance: store.settings.segmentMinDistance)
    }

    private func appendSessionPoint(_ location: CGPoint) {
        session.points.append(location)
        session.timedPoints.append(TimedGesturePoint(point: location, timestamp: eventTimestamp()))

        let overflow = session.points.count - Self.maxSessionPoints
        guard overflow > 0 else { return }
        session.points.removeFirst(overflow)
        session.timedPoints.removeFirst(min(overflow, session.timedPoints.count))
    }

    private func ingestMovement(to location: CGPoint, minimumDistance: Double) {
        let delta = CGSize(
            width: location.x - session.lastEventLocation.x,
            height: location.y - session.lastEventLocation.y
        )
        let distance = hypot(delta.width, delta.height)
        defer {
            session.lastEventLocation = location
        }

        guard distance >= 1, let direction = GestureDirection.from(delta: delta) else { return }

        if session.directions.last == direction {
            session.pendingDirection = nil
            session.pendingDistance = 0
            return
        }

        if session.pendingDirection == direction {
            session.pendingDistance += distance
        } else {
            session.pendingDirection = direction
            session.pendingDistance = distance
        }

        guard session.pendingDistance >= minimumDistance else { return }

        appendConfirmedDirection(direction)
        session.pendingDirection = nil
        session.pendingDistance = 0
    }

    private func appendConfirmedDirection(_ direction: GestureDirection) {
        if session.directions.last == direction { return }

        if session.directions.count >= 2,
           let previous = session.directions.dropLast().last,
           let bridge = session.directions.last,
           bridge.isDiagonalBridge(from: previous, to: direction) {
            session.directions.removeLast()
        }

        if session.directions.last != direction {
            session.directions.append(direction)
            trimSessionDirectionsIfNeeded()
        }
    }

    private func trimSessionDirectionsIfNeeded() {
        let overflow = session.directions.count - Self.maxSessionDirections
        guard overflow > 0 else { return }
        session.directions.removeFirst(overflow)
    }

    private func endSession(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard session.isActive else { return Unmanaged.passUnretained(event) }

        defer {
            session = GestureSession()
        }

        guard let store else { return nil }
        recordMovement(to: event.location, store: store)

        guard session.hasExceededThreshold else {
            replayRightClick(at: session.startLocation)
            hideHUDAfterDelay(id: session.id)
            return nil
        }

        updateHUD()
        let match = currentMatch(store: store)

        if let match {
            updateHUDSnapshot(id: session.id) { snapshot in
                snapshot.matchedAction = match.rule.actionTitle
                snapshot.message = match.rule.name
            }
            Task { [weak executor] in
                await executor?.execute(rule: match.rule)
            }
        } else {
            upsertHUDSnapshot(GestureHUDSnapshot(
                id: session.id,
                isVisible: store.settings.hudEnabled,
                points: session.points,
                timedPoints: session.timedPoints,
                screenFrame: session.screenFrame,
                directions: session.directions,
                currentDirection: currentDirection(),
                style: store.settings.hudStyle,
                message: store.matchFailureMessage(
                    directions: session.directions,
                    button: session.button,
                    modifiers: store.settings.triggerModifiers,
                    location: session.startLocation,
                    screenFrame: session.screenFrame,
                    frontmostApplication: appEnvironment?.frontmostApplication
                ),
                matchedAction: session.directions.map(\.title).joined(separator: " -> "),
                isError: true
            ))
        }
        hideHUDAfterDelay(id: session.id)
        return nil
    }

    private func cancelSession(message: String) {
        let cancelledSession = session
        if let store, store.settings.hudEnabled {
            upsertHUDSnapshot(GestureHUDSnapshot(
                id: cancelledSession.id,
                isVisible: true,
                points: cancelledSession.points,
                timedPoints: cancelledSession.timedPoints,
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

    private func updateHUD() {
        guard let store, store.settings.hudEnabled, !store.settings.hudOnlyForErrors else { return }
        let match = currentMatch(store: store)
        let isPotentialMatch = store.hasPotentialMatch(
            directions: session.directions,
            button: session.button,
            modifiers: store.settings.triggerModifiers,
            location: session.startLocation,
            screenFrame: session.screenFrame,
            frontmostApplication: appEnvironment?.frontmostApplication
        )
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
            points: session.points,
            timedPoints: session.timedPoints,
            screenFrame: session.screenFrame,
            directions: session.directions,
            currentDirection: currentDirection(),
            style: store.settings.hudStyle,
            message: message,
            matchedAction: matchedAction,
            isError: false,
            isCancelled: false
        ))
    }

    private func currentMatch(store: ConfigurationStore) -> GestureMatch? {
        store.match(
            directions: session.directions,
            button: session.button,
            modifiers: store.settings.triggerModifiers,
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
        hud = presentation
    }

    private func updateHUDSnapshot(id: UUID, update: (inout GestureHUDSnapshot) -> Void) {
        var presentation = hud
        guard let index = presentation.snapshots.firstIndex(where: { $0.id == id }) else { return }
        update(&presentation.snapshots[index])
        hud = presentation
    }

    private func markHUDSnapshotFading(id: UUID, duration: TimeInterval) {
        updateHUDSnapshot(id: id) { snapshot in
            snapshot.fadeStartedAt = Date()
            snapshot.fadeDuration = duration
        }
    }

    private func removeHUDSnapshot(id: UUID) {
        var presentation = hud
        presentation.snapshots.removeAll { $0.id == id }
        hud = presentation
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    private func currentDirection() -> GestureDirection? {
        guard session.hasExceededThreshold else { return nil }
        if let pendingDirection = session.pendingDirection {
            return pendingDirection
        }
        guard let current = session.points.last else { return session.directions.last }
        return GestureDirection.from(
            delta: CGSize(width: current.x - session.lastEventLocation.x, height: current.y - session.lastEventLocation.y)
        ) ?? session.directions.last
    }

    private func replayRightClick(at location: CGPoint) {
        guard session.button == .right else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: location, mouseButton: .right)
        let up = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: location, mouseButton: .right)
        down?.setIntegerValueField(.eventSourceUserData, value: Self.replayEventMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: Self.replayEventMarker)
        replayedRightClickEventsRemaining = 2
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func isRightClickReplayEvent(_ type: CGEventType) -> Bool {
        type == .rightMouseDown || type == .rightMouseUp
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
            switch buttonNumber {
            case 2: return .middle
            case 3: return .button4
            case 4: return .button5
            default: return nil
            }
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
    var lastEventLocation: CGPoint = .zero
    var pendingDirection: GestureDirection?
    var pendingDistance: Double = 0
    var points: [CGPoint] = []
    var timedPoints: [TimedGesturePoint] = []
    var directions: [GestureDirection] = []
}
