import Combine
import SwiftUI

@main
struct MowandApp: App {
    private static let mainWindowID = "main"

    @Environment(\.openWindow) private var openWindow
    @StateObject private var store = ConfigurationStore()
    @StateObject private var permissions = PermissionMonitor()
    @StateObject private var appEnvironment = AppEnvironment()
    @StateObject private var gestureEngine = GestureEngine()
    @StateObject private var actionExecutor = ActionExecutor()
    @StateObject private var rangeSelector = RangeSelectionCoordinator()
    @State private var hudWindowController: HUDWindowController?
    @State private var menuBarController: MenuBarController?

    var body: some Scene {
        WindowGroup("Mowand", id: Self.mainWindowID) {
            ContentView()
                .environmentObject(store)
                .environmentObject(permissions)
                .environmentObject(appEnvironment)
                .environmentObject(gestureEngine)
                .environmentObject(actionExecutor)
                .environmentObject(rangeSelector)
                .background(AppLifecycleView(onAppear: startServices))
                .onChange(of: permissions.accessibilityGranted) { _, granted in
                    if granted {
                        gestureEngine.start()
                    } else {
                        gestureEngine.stop()
                    }
                }
                .onChange(of: store.settings.gesturesEnabled) { _, enabled in
                    if enabled, permissions.accessibilityGranted {
                        gestureEngine.start()
                    } else if !enabled {
                        gestureEngine.stop()
                    }
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    private func openMainWindow() {
        if let window = NSApp.windows.first(where: { $0.title == "Mowand" }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: Self.mainWindowID)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func startServices() {
        permissions.start()
        appEnvironment.start()
        gestureEngine.configure(store: store, appEnvironment: appEnvironment, executor: actionExecutor)
        if permissions.accessibilityGranted {
            gestureEngine.start()
        }
        hudWindowController = HUDWindowController(engine: gestureEngine)
        if menuBarController == nil {
            menuBarController = MenuBarController(
                store: store,
                openMowand: openMainWindow,
                quitMowand: {
                    store.saveNow()
                    NSApp.terminate(nil)
                }
            )
        }

        if store.settings.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct AppLifecycleView: NSViewRepresentable {
    let onAppear: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onAppear()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class MenuBarController: NSObject {
    private let store: ConfigurationStore
    private let openMowand: () -> Void
    private let quitMowand: () -> Void
    private let statusItem: NSStatusItem
    private let gestureMenuItem = NSMenuItem()
    private var cancellables: Set<AnyCancellable> = []

    init(store: ConfigurationStore, openMowand: @escaping () -> Void, quitMowand: @escaping () -> Void) {
        self.store = store
        self.openMowand = openMowand
        self.quitMowand = quitMowand
        self.statusItem = NSStatusBar.system.statusItem(withLength: 14)
        super.init()
        configureStatusItem()
        configureMenu()
        updateGestureMenuTitle()

        store.$configuration
            .sink { [weak self] _ in
                self?.updateGestureMenuTitle()
            }
            .store(in: &cancellables)
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusItem() {
        statusItem.length = 14
        statusItem.button?.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Mowand")
        statusItem.button?.imagePosition = .imageOnly
    }

    private func configureMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "打开Mowand", action: #selector(openMowandAction), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        gestureMenuItem.action = #selector(toggleGesturesAction)
        gestureMenuItem.target = self
        menu.addItem(gestureMenuItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出Mowand", action: #selector(quitMowandAction), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateGestureMenuTitle() {
        gestureMenuItem.title = store.settings.gesturesEnabled ? "关闭全局手势" : "开启全局手势"
    }

    @objc private func openMowandAction() {
        openMowand()
    }

    @objc private func toggleGesturesAction() {
        store.updateSettings { settings in
            settings.gesturesEnabled.toggle()
        }
    }

    @objc private func quitMowandAction() {
        quitMowand()
    }
}
