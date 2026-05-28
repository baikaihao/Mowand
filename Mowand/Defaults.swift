import Foundation

enum DefaultTemplates {
    static func makeRules(now: Date = Date()) -> [GestureRule] {
        [
            rule("选区截图", [.northEast, .southEast], .screenshotSelection, screenshotExecutionMode: .shortcut, now: now),
            rule("粘贴", [.southEast, .northEast], .paste, now: now),
            rule("系统睡眠", [.west, .south, .east, .south, .west], .systemSleep, now: now),
            rule("提高音量", [.north], .volumeUp, region: ScreenRegion(kind: .topRightQuarter), now: now),
            rule("降低音量", [.south], .volumeDown, region: ScreenRegion(kind: .topRightQuarter), now: now),
            rule("刷新", [.east, .south], .refresh, now: now),
            rule("关闭窗口", [.southWest, .north, .southEast], .closeWindow, now: now),
            rule("最小化窗口", [.southEast, .southWest], .minimizeWindow, now: now)
        ]
    }

    private static func rule(
        _ name: String,
        _ directions: [GestureDirection],
        _ action: SystemAction,
        region: ScreenRegion = .full,
        screenshotExecutionMode: ScreenshotExecutionMode = .direct,
        now: Date
    ) -> GestureRule {
        GestureRule(
            name: name,
            scope: .global,
            triggerButton: .right,
            modifiers: ModifierFlags(),
            region: region,
            directions: directions,
            actions: [ActionStep(type: .system(action), screenshotExecutionMode: screenshotExecutionMode)],
            createdAt: now,
            updatedAt: now,
            isDefaultTemplate: true
        )
    }
}
