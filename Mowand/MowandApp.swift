import SwiftUI

@main
struct MowandApp: App {
    @StateObject private var store = ConfigurationStore()
    @StateObject private var permissions = PermissionMonitor()
    @StateObject private var appEnvironment = AppEnvironment()
    @StateObject private var gestureEngine = GestureEngine()
    @StateObject private var actionExecutor = ActionExecutor()
    @StateObject private var rangeSelector = RangeSelectionCoordinator()
    @State private var hudWindowController: HUDWindowController?

    var body: some Scene {
        WindowGroup("Mowand") {
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

        MenuBarExtra("Mowand", systemImage: "wand.and.stars") {
            Toggle("启用全局手势", isOn: Binding(
                get: { store.settings.gesturesEnabled },
                set: { enabled in store.updateSettings { $0.gesturesEnabled = enabled } }
            ))

            Button("打开设置") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title == "Mowand" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            Divider()

            Label(
                permissions.accessibilityGranted ? "辅助功能权限已开启" : "辅助功能权限未开启",
                systemImage: permissions.accessibilityGranted ? "checkmark.circle" : "exclamationmark.triangle"
            )

            if !permissions.accessibilityGranted {
                Button("打开辅助功能授权") {
                    permissions.requestAccessibilityPermission()
                }
            }

            Divider()

            Button("退出 Mowand") {
                store.saveNow()
                NSApp.terminate(nil)
            }
        }
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
