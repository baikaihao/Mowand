import Foundation
import SwiftUI

struct HUDOverlay: View {
    let presentation: GestureHUDPresentation

    init(snapshot: GestureHUDSnapshot) {
        self.presentation = GestureHUDPresentation(snapshots: [snapshot])
    }

    init(presentation: GestureHUDPresentation) {
        self.presentation = presentation
    }

    var body: some View {
        GeometryReader { proxy in
            if presentation.isVisible {
                if hasFadingSnapshots {
                    TimelineView(.animation) { timeline in
                        snapshotStack(date: timeline.date)
                    }
                } else {
                    snapshotStack(date: Date())
                }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func snapshotStack(date: Date) -> some View {
        ZStack {
            let guideSnapshotID = activeGuideSnapshotID
            ForEach(presentation.snapshots) { snapshot in
                HUDSnapshotLayer(
                    snapshot: snapshot,
                    showsDirectionGuide: snapshot.id == guideSnapshotID
                )
                .opacity(opacity(for: snapshot, at: date))
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func opacity(for snapshot: GestureHUDSnapshot, at date: Date) -> Double {
        guard let fadeStartedAt = snapshot.fadeStartedAt else { return snapshot.isVisible ? 1 : 0 }
        let elapsed = date.timeIntervalSince(fadeStartedAt)
        let progress = min(max(elapsed / snapshot.fadeDuration, 0), 1)
        return snapshot.isVisible ? 1 - progress : 0
    }

    private var activeGuideSnapshotID: UUID? {
        presentation.snapshots.last(where: { $0.isVisible && $0.fadeStartedAt == nil })?.id
    }

    private var hasFadingSnapshots: Bool {
        presentation.snapshots.contains { $0.fadeStartedAt != nil }
    }
}

private struct HUDSnapshotLayer: View {
    let snapshot: GestureHUDSnapshot
    let showsDirectionGuide: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            if snapshot.isVisible {
                ZStack {
                    let points = normalizedPoints(in: proxy.size)

                    if snapshot.style.showTrajectory {
                        GesturePath(points: points)
                            .stroke(pathColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                            .shadow(radius: 5)
                    }

                    if showsDirectionGuide, snapshot.style.showDirectionGuide, let pointer = points.last {
                        SmoothDirectionGuideContainer(
                            style: snapshot.style,
                            currentDirection: snapshot.currentDirection,
                            targetPosition: pointer
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: iconName)
                                .foregroundStyle(pathColor)
                            Text(snapshot.message)
                                .font(.headline)
                        }

                        if !snapshot.directions.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(snapshot.directions) { direction in
                                    Text(direction.title)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        if let matchedAction = snapshot.matchedAction, !matchedAction.isEmpty {
                            Text(matchedAction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(glassPanelBackground)
                    .position(panelPosition(in: proxy.size))
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var pathColor: Color {
        if snapshot.isError { return .red }
        if snapshot.isCancelled { return .orange }
        return snapshot.style.highlightedColor.color
    }

    private var iconName: String {
        if snapshot.isError { return "exclamationmark.triangle" }
        if snapshot.isCancelled { return "xmark.circle" }
        return "wand.and.stars"
    }

    private var glassPanelBackground: some View {
        let fill = colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.2)
        let stroke = colorScheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.58)
        return RoundedRectangle(cornerRadius: 8)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard let screenFrame = snapshot.screenFrame else { return snapshot.points }
        return snapshot.points.map { point in
            CGPoint(
                x: point.x - screenFrame.minX,
                y: point.y - screenFrame.minY
            )
        }
    }

    private func panelPosition(in size: CGSize) -> CGPoint {
        let points = normalizedPoints(in: size)
        guard !points.isEmpty else {
            return CGPoint(x: size.width / 2, y: 90)
        }
        let minX = points.map(\.x).min() ?? size.width / 2
        let maxX = points.map(\.x).max() ?? size.width / 2
        let minY = points.map(\.y).min() ?? size.height / 2
        let maxY = points.map(\.y).max() ?? size.height / 2
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        return CGPoint(
            x: min(max(center.x + 120, 180), size.width - 180),
            y: min(max(center.y - 80, 80), size.height - 80)
        )
    }
}

private struct SmoothDirectionGuideContainer: View {
    let style: HUDSettings
    let currentDirection: GestureDirection?
    let targetPosition: CGPoint

    @State private var displayPosition: CGPoint?

    var body: some View {
        DirectionGuideView(
            style: style,
            currentDirection: currentDirection
        )
        .frame(
            width: style.directionGuideRadius * 2,
            height: style.directionGuideRadius * 2
        )
        .position(displayPosition ?? targetPosition)
        .onAppear {
            displayPosition = targetPosition
        }
        .onChange(of: targetPosition) { _, newValue in
            if displayPosition == nil {
                displayPosition = newValue
            } else {
                withAnimation(.interactiveSpring(response: responseDuration, dampingFraction: 0.82, blendDuration: 0.04)) {
                    displayPosition = newValue
                }
            }
        }
        .onChange(of: style.directionGuideSmoothing) { _, _ in
            displayPosition = targetPosition
        }
    }

    private var responseDuration: Double {
        max(0.04, 0.06 + style.directionGuideSmoothing * 0.8)
    }
}

private struct DirectionGuideView: View {
    let style: HUDSettings
    let currentDirection: GestureDirection?

    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let innerRadius = max(10, radius * 0.16)
            let normalColor = style.normalLineColor.color.opacity(style.directionGuideOpacity)
            let highlightColor = style.highlightedColor.color.opacity(min(1, style.directionGuideOpacity + 0.16))

            ZStack {
                Circle()
                    .stroke(normalColor.opacity(0.5), lineWidth: style.directionGuideLineWidth)

                if let currentDirection {
                    DirectionSectorShape(
                        direction: currentDirection,
                        innerRadius: innerRadius,
                        outerRadius: radius
                    )
                    .fill(highlightColor.opacity(0.22))
                }

                DirectionBoundaryShape(innerRadius: innerRadius, outerRadius: radius)
                    .stroke(normalColor, style: StrokeStyle(lineWidth: style.directionGuideLineWidth, lineCap: .round))

                Circle()
                    .fill(.black.opacity(0.22))
                    .frame(width: innerRadius * 2, height: innerRadius * 2)
                    .position(center)

                ForEach(GestureDirection.allCases) { direction in
                    let isCurrent = direction == currentDirection
                    let itemRadius = radius * 0.68
                    let point = point(from: center, angleDegrees: direction.angleDegrees, radius: itemRadius)

                    VStack(spacing: 1) {
                        if style.showDirectionArrows {
                            Image(systemName: direction.symbolName)
                                .font(.system(size: arrowSize(isCurrent: isCurrent), weight: isCurrent ? .bold : .medium))
                        }
                        if style.showDirectionLabels {
                            Text(style.showDirectionArrows ? direction.textTitle : direction.title)
                                .font(.system(size: labelSize(isCurrent: isCurrent), weight: isCurrent ? .bold : .medium))
                        }
                    }
                    .foregroundStyle(isCurrent ? highlightColor : normalColor)
                    .shadow(color: .black.opacity(0.28), radius: 2)
                    .position(point)
                }
            }
        }
    }

    private func point(from center: CGPoint, angleDegrees: Double, radius: Double) -> CGPoint {
        let radians = angleDegrees * .pi / 180
        return CGPoint(
            x: center.x + cos(radians) * radius,
            y: center.y + sin(radians) * radius
        )
    }

    private func arrowSize(isCurrent: Bool) -> Double {
        isCurrent ? style.directionGuideArrowSize * 1.3 : style.directionGuideArrowSize
    }

    private func labelSize(isCurrent: Bool) -> Double {
        isCurrent ? style.directionGuideFontSize * 1.22 : style.directionGuideFontSize
    }
}

private struct DirectionBoundaryShape: Shape {
    let innerRadius: Double
    let outerRadius: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for index in 0..<8 {
            let radians = (22.5 + Double(index) * 45) * .pi / 180
            let inner = CGPoint(
                x: center.x + cos(radians) * innerRadius,
                y: center.y + sin(radians) * innerRadius
            )
            let outer = CGPoint(
                x: center.x + cos(radians) * outerRadius,
                y: center.y + sin(radians) * outerRadius
            )
            path.move(to: inner)
            path.addLine(to: outer)
        }
        return path
    }
}

private struct DirectionSectorShape: Shape {
    let direction: GestureDirection
    let innerRadius: Double
    let outerRadius: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = direction.angleDegrees - 22.5
        let end = direction.angleDegrees + 22.5
        var path = Path()
        let outerStart = point(from: center, angleDegrees: start, radius: outerRadius)
        path.move(to: outerStart)

        for step in 1...16 {
            let angle = start + (end - start) * Double(step) / 16
            path.addLine(to: point(from: center, angleDegrees: angle, radius: outerRadius))
        }

        for step in stride(from: 16, through: 0, by: -1) {
            let angle = start + (end - start) * Double(step) / 16
            path.addLine(to: point(from: center, angleDegrees: angle, radius: innerRadius))
        }

        path.closeSubpath()
        return path
    }

    private func point(from center: CGPoint, angleDegrees: Double, radius: Double) -> CGPoint {
        let radians = angleDegrees * .pi / 180
        return CGPoint(
            x: center.x + cos(radians) * radius,
            y: center.y + sin(radians) * radius
        )
    }
}

private struct GesturePath: Shape {
    var points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }
}
