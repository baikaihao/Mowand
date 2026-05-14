import AppKit
import Combine
import SwiftUI

@MainActor
final class HUDWindowController {
    private let window: NSWindow
    private let presentationModel = HUDPresentationModel()
    private var cancellable: AnyCancellable?

    init(engine: GestureEngine) {
        let screenFrame = NSScreen.main?.frame ?? .zero
        let hostingView = NSHostingView(rootView: HUDOverlayHost(model: presentationModel))
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
        window.contentView = hostingView

        cancellable = engine.$hud.sink { [weak self] presentation in
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
