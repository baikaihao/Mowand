import CoreGraphics
import Foundation

enum GestureTemplateRecognizer {
    nonisolated private static let sampleCount = 32
    nonisolated private static let minimumPathLength = 24.0
    nonisolated private static let minimumRuleScore = 0.78
    nonisolated private static let minimumDirectionScore = 0.72
    nonisolated private static let maxGeneratedSegments = 4
    nonisolated private static let maxRealtimeGeneratedSegments = 3
    nonisolated private static let cachedDirectionTemplateVectors: [[DirectionTemplateVector]] = {
        (1...maxGeneratedSegments).map { segmentCount in
            directionTemplates(segmentCount: segmentCount).compactMap { directions in
                guard let vector = vector(forTemplate: directions) else { return nil }
                return DirectionTemplateVector(directions: directions, vector: vector)
            }
        }
    }()

    nonisolated static func bestMatch(points: [CGPoint], candidates: [GestureRuleCandidate]) -> GestureRuleCandidate? {
        guard let gestureVector = vector(forStroke: points) else { return nil }
        return bestMatch(gestureVector: gestureVector, candidates: candidates)
    }

    nonisolated static func bestMatch(gestureVector: [Double], candidates: [GestureRuleCandidate]) -> GestureRuleCandidate? {
        var bestCandidate: GestureRuleCandidate?
        var highestScore = -Double.infinity
        for candidate in candidates {
            guard let score = bestScore(for: gestureVector, rule: candidate.rule) else { continue }
            if score > highestScore {
                highestScore = score
                bestCandidate = candidate
            }
        }

        guard highestScore >= minimumRuleScore else { return nil }
        return bestCandidate
    }

    nonisolated static func bestMatch(gestureVector: [Double], candidates: [GestureTemplateCandidate]) -> GestureTemplateCandidate? {
        var bestCandidate: GestureTemplateCandidate?
        var highestScore = -Double.infinity
        for candidate in candidates {
            let score = bestScore(for: gestureVector, templateVectors: candidate.templateVectors)
            if score > highestScore {
                highestScore = score
                bestCandidate = candidate
            }
        }

        guard highestScore >= minimumRuleScore else { return nil }
        return bestCandidate
    }

    nonisolated static func templateVectors(for rule: GestureRule) -> [[Double]] {
        guard let directionVector = vector(forTemplate: rule.directions) else { return [] }
        return [directionVector]
    }

    nonisolated private static func bestScore(for gestureVector: [Double], rule: GestureRule) -> Double? {
        let templateVectors = templateVectors(for: rule)
        guard !templateVectors.isEmpty else { return nil }
        return bestScore(for: gestureVector, templateVectors: templateVectors)
    }

    nonisolated private static func bestScore(for gestureVector: [Double], templateVectors: [[Double]]) -> Double {
        templateVectors.map { similarity(between: gestureVector, and: $0) }.max() ?? -Double.infinity
    }

    nonisolated static func bestDirections(points: [CGPoint], segmentCount: Int) -> [GestureDirection]? {
        guard let gestureVector = vector(forStroke: points) else { return nil }
        return bestDirections(gestureVector: gestureVector, segmentCount: segmentCount, isRealtime: false)
    }

    nonisolated static func bestDirections(gestureVector: [Double], segmentCount: Int, isRealtime: Bool) -> [GestureDirection]? {
        let maxSegments = isRealtime ? maxRealtimeGeneratedSegments : maxGeneratedSegments
        let clampedSegmentCount = min(max(1, segmentCount), maxSegments)
        let candidates = directionTemplateVectors(segmentCount: clampedSegmentCount)

        var bestDirections: [GestureDirection]?
        var bestScore = -Double.infinity
        for candidate in candidates {
            let score = similarity(between: gestureVector, and: candidate.vector)
            if score > bestScore {
                bestScore = score
                bestDirections = candidate.directions
            }
        }

        guard bestScore >= minimumDirectionScore else { return nil }
        return bestDirections
    }

    nonisolated private static func directionTemplates(segmentCount: Int) -> [[GestureDirection]] {
        guard segmentCount > 1 else {
            return GestureDirection.allCases.map { [$0] }
        }

        var templates: [[GestureDirection]] = GestureDirection.allCases.map { [$0] }
        for _ in 1..<segmentCount {
            templates = templates.flatMap { prefix in
                GestureDirection.allCases.compactMap { direction in
                    guard direction != prefix.last else { return nil }
                    var next = prefix
                    next.append(direction)
                    return next
                }
            }
        }
        return templates
    }

    nonisolated private static func directionTemplateVectors(segmentCount: Int) -> [DirectionTemplateVector] {
        let index = min(maxGeneratedSegments, max(1, segmentCount)) - 1
        return cachedDirectionTemplateVectors[index]
    }

    nonisolated static func vector(forStroke points: [CGPoint]) -> [Double]? {
        guard points.count >= 3, pathLength(points) >= minimumPathLength else { return nil }
        return normalizedVector(points: points)
    }

    nonisolated private static func vector(forTemplate directions: [GestureDirection]) -> [Double]? {
        guard !directions.isEmpty else { return nil }

        var points = [CGPoint.zero]
        var current = CGPoint.zero
        for direction in directions {
            let components = direction.components
            current = CGPoint(
                x: current.x + Double(components.x),
                y: current.y + Double(components.y)
            )
            points.append(current)
        }
        return normalizedVector(points: points)
    }

    nonisolated private static func similarity(between lhs: [Double], and rhs: [Double]) -> Double {
        zip(lhs, rhs).reduce(0.0) { partial, pair in
            partial + pair.0 * pair.1
        }
    }

    nonisolated private static func normalizedVector(points: [CGPoint]) -> [Double]? {
        let sampledPoints = resample(points, targetCount: sampleCount)
        guard sampledPoints.count == sampleCount else { return nil }

        let minX = sampledPoints.map(\.x).min() ?? 0
        let maxX = sampledPoints.map(\.x).max() ?? 0
        let minY = sampledPoints.map(\.y).min() ?? 0
        let maxY = sampledPoints.map(\.y).max() ?? 0
        let width = maxX - minX
        let height = maxY - minY
        let maxExtent = max(width, height)
        guard maxExtent > 0 else { return nil }

        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        let minimumAxisExtent = maxExtent * 0.1
        let scaleX = width >= minimumAxisExtent ? width : maxExtent
        let scaleY = height >= minimumAxisExtent ? height : maxExtent

        var vector: [Double] = []
        vector.reserveCapacity(sampledPoints.count * 2)
        for point in sampledPoints {
            vector.append((point.x - centerX) / scaleX)
            vector.append((point.y - centerY) / scaleY)
        }

        let magnitude = sqrt(vector.reduce(0.0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return nil }
        return vector.map { $0 / magnitude }
    }

    nonisolated private static func resample(_ points: [CGPoint], targetCount: Int) -> [CGPoint] {
        guard targetCount > 1, points.count > 1 else { return points }

        let totalLength = pathLength(points)
        guard totalLength > 0 else { return points }

        let interval = totalLength / Double(targetCount - 1)
        var sampledPoints: [CGPoint] = []
        sampledPoints.reserveCapacity(targetCount)

        var accumulatedLength = 0.0
        var targetDistance = 0.0

        for index in points.indices.dropLast() {
            let start = points[index]
            let end = points[index + 1]
            let segmentLength = distance(from: start, to: end)
            guard segmentLength > 0 else { continue }

            while targetDistance <= accumulatedLength + segmentLength,
                  sampledPoints.count < targetCount {
                let progress = (targetDistance - accumulatedLength) / segmentLength
                sampledPoints.append(CGPoint(
                    x: start.x + (end.x - start.x) * progress,
                    y: start.y + (end.y - start.y) * progress
                ))
                targetDistance += interval
            }

            accumulatedLength += segmentLength
        }

        while sampledPoints.count < targetCount, let last = points.last {
            sampledPoints.append(last)
        }

        return Array(sampledPoints.prefix(targetCount))
    }

    nonisolated private static func pathLength(_ points: [CGPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        return points.indices.dropLast().reduce(0.0) { partial, index in
            partial + distance(from: points[index], to: points[index + 1])
        }
    }

    nonisolated private static func distance(from start: CGPoint, to end: CGPoint) -> Double {
        hypot(end.x - start.x, end.y - start.y)
    }

    private struct DirectionTemplateVector {
        var directions: [GestureDirection]
        var vector: [Double]
    }
}
