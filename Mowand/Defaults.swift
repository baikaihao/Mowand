import Foundation

enum DefaultTemplates {
    static func makeRules(now: Date = Date()) -> [GestureRule] {
        [
            rule("返回", [.west], .back, now: now),
            rule("前进", [.east], .forward, now: now),
            rule("降低音量", [.south], .volumeDown, now: now),
            rule("提高音量", [.north], .volumeUp, now: now),
            rule("刷新", [.east, .south], .refresh, now: now),
            rule("截图工具", [.south, .east], .screenshot, now: now),
            rule("显示桌面", [.north, .south], .showDesktop, now: now),
            rule("切换最近使用的 App", [.west, .east], .switchRecentApp, now: now),
            rule("提高亮度", [.northEast], .brightnessUp, now: now),
            rule("降低亮度", [.southEast], .brightnessDown, now: now),
            rule("静音", [.southWest], .mute, now: now),
            rule("锁屏", [.northWest], .lockScreen, now: now)
        ]
    }

    private static func rule(
        _ name: String,
        _ directions: [GestureDirection],
        _ action: SystemAction,
        now: Date
    ) -> GestureRule {
        GestureRule(
            name: name,
            scope: .global,
            triggerButton: .right,
            modifiers: ModifierFlags(),
            region: .full,
            directions: directions,
            actions: [ActionStep(type: .system(action))],
            createdAt: now,
            updatedAt: now,
            isDefaultTemplate: true
        )
    }
}
