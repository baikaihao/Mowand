import AppKit
import Combine
import SwiftUI

@MainActor
final class HUDWindowController {
    private let window: NSWindow
    private var cancellable: AnyCancellable?

    init(engine: GestureEngine) {
        let screenFrame = NSScreen.main?.frame ?? .zero
        let hostingView = NSHostingView(rootView: HUDOverlay(snapshot: GestureHUDSnapshot()))
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

        cancellable = engine.$hud.sink { [weak self] snapshot in
            guard let self else { return }
            let screenFrame = snapshot.screenFrame ?? NSScreen.main?.frame ?? self.window.frame
            self.window.setFrame(screenFrame, display: false)
            self.window.contentView = NSHostingView(rootView: HUDOverlay(snapshot: snapshot))
            if snapshot.isVisible {
                self.window.orderFrontRegardless()
            } else {
                self.window.orderOut(nil)
            }
        }
    }
}
