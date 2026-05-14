import AppKit
import Combine
import SwiftUI

@MainActor
final class RangeSelectionCoordinator: ObservableObject {
    private var window: NSWindow?
    private var completion: ((NormalizedRect?) -> Void)?

    func selectRange(completion: @escaping (NormalizedRect?) -> Void) {
        guard window == nil, let screen = NSScreen.main else {
            completion(nil)
            return
        }

        self.completion = completion
        let view = RangeSelectionOverlay(screenFrame: screen.frame) { [weak self] rect in
            self?.finish(rect)
        }

        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func finish(_ rect: NormalizedRect?) {
        window?.orderOut(nil)
        window = nil
        completion?(rect)
        completion = nil
    }
}

private struct RangeSelectionOverlay: View {
    let screenFrame: CGRect
    let onComplete: (NormalizedRect?) -> Void

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()

                if let selectionRect {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay(
                            Rectangle()
                                .stroke(Color.accentColor, lineWidth: 2)
                        )
                        .frame(width: selectionRect.width, height: selectionRect.height)
                        .position(x: selectionRect.midX, y: selectionRect.midY)
                }

                VStack(spacing: 8) {
                    Text("拖拽选择屏幕范围")
                        .font(.headline)
                    Text("按 Esc 取消")
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .position(x: proxy.size.width / 2, y: 70)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if start == nil { start = value.startLocation }
                        current = value.location
                    }
                    .onEnded { value in
                        let startPoint = start ?? value.startLocation
                        let endPoint = value.location
                        let rect = CGRect(
                            x: min(startPoint.x, endPoint.x),
                            y: min(startPoint.y, endPoint.y),
                            width: abs(startPoint.x - endPoint.x),
                            height: abs(startPoint.y - endPoint.y)
                        )
                        guard rect.width >= 12, rect.height >= 12 else {
                            onComplete(nil)
                            return
                        }
                        onComplete(
                            NormalizedRect(
                                x: rect.minX / proxy.size.width,
                                y: rect.minY / proxy.size.height,
                                width: rect.width / proxy.size.width,
                                height: rect.height / proxy.size.height
                            )
                        )
                    }
            )
            .onExitCommand {
                onComplete(nil)
            }
        }
    }

    private var selectionRect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
    }
}
