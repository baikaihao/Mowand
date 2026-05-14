import AppKit
import Combine
import SwiftUI

@MainActor
final class HUDWindowController {
    private let window: NSWindow
    private let trajectoryView = HUDTrajectoryView()
    private let presentationModel = HUDPresentationModel()
    private var cancellables: Set<AnyCancellable> = []

    init(engine: GestureEngine) {
        let screenFrame = NSScreen.main?.frame ?? .zero
        let hostingView = NSHostingView(rootView: HUDOverlayHost(model: presentationModel))
        let contentView = HUDContainerView(frame: screenFrame)
        contentView.autoresizingMask = [.width, .height]
        trajectoryView.frame = contentView.bounds
        trajectoryView.autoresizingMask = [.width, .height]
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(trajectoryView)
        contentView.addSubview(hostingView)

        window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = contentView

        engine.$hud.sink { [weak self] presentation in
            guard let self else { return }
            let screenFrame = presentation.screenFrame ?? NSScreen.main?.frame ?? self.window.frame
            if self.window.frame != screenFrame {
                self.window.setFrame(screenFrame, display: false)
            }
            self.presentationModel.presentation = presentation
            if presentation.isVisible {
                if !self.window.isVisible {
                    self.window.orderFrontRegardless()
                }
            } else if self.window.isVisible {
                self.window.orderOut(nil)
            }
        }
        .store(in: &cancellables)

        engine.$trajectory.sink { [weak self] presentation in
            self?.trajectoryView.presentation = presentation
        }
        .store(in: &cancellables)
    }
}

private final class HUDContainerView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class HUDTrajectoryView: NSView {
    var presentation = GestureTrajectoryPresentation() {
        didSet {
            updateLayers()
        }
    }

    private var shapeLayers: [UUID: CAShapeLayer] = [:]
    private var fadeTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shapeLayer in shapeLayers.values {
            shapeLayer.frame = bounds
        }
        CATransaction.commit()
        updateLayers()
    }

    private func updateLayers() {
        guard let layer else { return }
        let visibleIDs = Set(presentation.snapshots.map(\.id))
        for (id, shapeLayer) in shapeLayers where !visibleIDs.contains(id) {
            shapeLayer.removeFromSuperlayer()
            shapeLayers[id] = nil
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for snapshot in presentation.snapshots {
            let shapeLayer = shapeLayer(for: snapshot.id, in: layer)
            shapeLayer.frame = bounds
            shapeLayer.path = path(for: snapshot).cgPath
            shapeLayer.strokeColor = strokeColor(for: snapshot)
            shapeLayer.opacity = Float(opacity(for: snapshot))
        }
        CATransaction.commit()
        updateFadeTimer()
    }

    private func shapeLayer(for id: UUID, in rootLayer: CALayer) -> CAShapeLayer {
        if let shapeLayer = shapeLayers[id] {
            return shapeLayer
        }

        let shapeLayer = CAShapeLayer()
        shapeLayer.fillColor = nil
        shapeLayer.lineWidth = 4
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        shapeLayer.shadowColor = NSColor.black.cgColor
        shapeLayer.shadowOpacity = 0.32
        shapeLayer.shadowRadius = 5
        shapeLayer.shadowOffset = .zero
        rootLayer.addSublayer(shapeLayer)
        shapeLayers[id] = shapeLayer
        return shapeLayer
    }

    private func path(for snapshot: GestureTrajectorySnapshot) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = snapshot.points.first else { return path }
        let offsetX = snapshot.screenFrame?.minX ?? 0
        let offsetY = snapshot.screenFrame?.minY ?? 0
        path.move(to: CGPoint(x: first.x - offsetX, y: first.y - offsetY))
        for point in snapshot.points.dropFirst() {
            path.line(to: CGPoint(x: point.x - offsetX, y: point.y - offsetY))
        }
        return path
    }

    private func strokeColor(for snapshot: GestureTrajectorySnapshot) -> CGColor {
        if snapshot.isError { return NSColor.systemRed.cgColor }
        if snapshot.isCancelled { return NSColor.systemOrange.cgColor }
        return snapshot.style.highlightedColor.nsColor.cgColor
    }

    private func opacity(for snapshot: GestureTrajectorySnapshot) -> CGFloat {
        guard let fadeStartedAt = snapshot.fadeStartedAt else { return snapshot.isVisible ? 1 : 0 }
        let elapsed = Date().timeIntervalSince(fadeStartedAt)
        let progress = min(max(elapsed / snapshot.fadeDuration, 0), 1)
        return snapshot.isVisible ? 1 - progress : 0
    }

    private func updateFadeTimer() {
        let hasFadingSnapshots = presentation.snapshots.contains { snapshot in
            guard let fadeStartedAt = snapshot.fadeStartedAt else { return false }
            return Date().timeIntervalSince(fadeStartedAt) < snapshot.fadeDuration
        }

        if hasFadingSnapshots, fadeTimer == nil {
            fadeTimer = Timer.scheduledTimer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(fadeTimerDidFire(_:)),
                userInfo: nil,
                repeats: true
            )
        } else if !hasFadingSnapshots {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    @objc private func fadeTimerDidFire(_ timer: Timer) {
        updateLayers()
    }
}

private extension HUDColorPreset {
    var nsColor: NSColor {
        switch self {
        case .blue: return .systemBlue
        case .cyan: return .systemCyan
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .purple: return .systemPurple
        case .white: return .white
        }
    }
}

@MainActor
private final class HUDPresentationModel: ObservableObject {
    @Published var presentation = GestureHUDPresentation()
}

private struct HUDOverlayHost: View {
    @ObservedObject var model: HUDPresentationModel

    var body: some View {
        HUDOverlay(presentation: model.presentation)
    }
}
