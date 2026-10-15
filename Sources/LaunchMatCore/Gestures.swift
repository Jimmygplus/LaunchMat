import CoreGraphics

public enum HotCorner: String, CaseIterable, Sendable {
    case off, topLeft, topRight, bottomLeft, bottomRight

    /// `point` and `frame` in AppKit screen coordinates (origin bottom-left).
    public func contains(_ point: CGPoint, in frame: CGRect, tolerance: CGFloat = 3) -> Bool {
        let left = point.x <= frame.minX + tolerance
        let right = point.x >= frame.maxX - 1 - tolerance
        let top = point.y >= frame.maxY - 1 - tolerance
        let bottom = point.y <= frame.minY + tolerance
        switch self {
        case .off: return false
        case .topLeft: return top && left
        case .topRight: return top && right
        case .bottomLeft: return bottom && left
        case .bottomRight: return bottom && right
        }
    }
}

/// Fires once when the cursor rests in the corner for `dwell` seconds; re-arms after it leaves.
public struct HotCornerTrigger: Sendable {
    public var corner: HotCorner
    public var dwell: Double
    private var enteredAt: Double?
    private var armed = true

    public init(corner: HotCorner, dwell: Double = 0.12) {
        self.corner = corner
        self.dwell = dwell
    }

    public mutating func update(point: CGPoint, screen: CGRect, time: Double) -> Bool {
        guard corner.contains(point, in: screen) else {
            armed = true
            enteredAt = nil
            return false
        }
        guard armed else { return false }
        if let t = enteredAt, time - t >= dwell {
            armed = false
            enteredAt = nil
            return true
        }
        if enteredAt == nil { enteredAt = time }
        return false
    }
}

public enum PinchFingers: String, CaseIterable, Sendable {
    case off, three, fourOrFive

    public var range: ClosedRange<Int>? {
        switch self {
        case .off: return nil
        case .three: return 3...3
        case .fourOrFive: return 4...5
        }
    }
}

/// Recognizes a pinch from raw normalized trackpad touch positions: the mean distance of the fingers
/// from their centroid shrinking (pinch in) or growing (pinch out) past a ratio. One gesture per touch sequence.
public struct PinchDetector: Sendable {
    public enum Gesture: Equatable, Sendable { case pinchIn, pinchOut }

    public var fingers: ClosedRange<Int>
    public var inRatio: Double = 0.62
    public var outRatio: Double = 1.5
    private var startSpread: Double?
    private var fired = false

    public init(fingers: ClosedRange<Int>) { self.fingers = fingers }

    public mutating func update(_ points: [CGPoint]) -> Gesture? {
        if points.isEmpty {
            startSpread = nil
            fired = false
            return nil
        }
        guard fingers.contains(points.count) else {
            startSpread = nil // finger count changed mid-gesture: start measuring again
            return nil
        }
        let spread = Self.spread(points)
        guard let start = startSpread else {
            startSpread = spread
            return nil
        }
        guard !fired, start > 0.01 else { return nil }
        let ratio = spread / start
        if ratio <= inRatio {
            fired = true
            return .pinchIn
        }
        if ratio >= outRatio {
            fired = true
            return .pinchOut
        }
        return nil
    }

    static func spread(_ points: [CGPoint]) -> Double {
        let cx = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let cy = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        let total = points.map { Double(hypot($0.x - cx, $0.y - cy)) }.reduce(0, +)
        return total / Double(points.count)
    }
}
