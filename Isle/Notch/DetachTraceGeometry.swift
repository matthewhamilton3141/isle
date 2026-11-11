//
//  DetachTraceGeometry.swift
//
//  The path the detach line takes round the island: the island's outline,
//  cut into two halves that both start at its bottom centre and run up
//  opposite sides to meet at the top — where the island joins the notch.
//
//  Works on whatever closed outline it's given rather than on the notch
//  shape's own construction, so a different outline (the island's shape off
//  the notch) needs nothing here. Coordinates are the outline's own, y
//  down, as SwiftUI draws it.
//
//  CoreGraphics only, so it's checked without a view
//  (scripts/test-island-placement.sh).
//

import CoreGraphics

enum DetachTraceGeometry {
    struct Halves {
        /// From `start` up the left side, and up the right, as polylines.
        var left: CGPath
        var right: CGPath
        /// The bottom centre, where both begin.
        var start: CGPoint
        /// Where each ends, at the top.
        var leftEnd: CGPoint
        var rightEnd: CGPoint
        /// The length of each, in points.
        var leftLength: CGFloat
        var rightLength: CGFloat
    }

    /// The two halves of `outline`, or nil for something that isn't a closed
    /// outline with a top and a bottom on its centre line.
    ///
    /// `topGap` is a width at the top centre the line stops short of: the
    /// camera housing. The outline's top edge runs behind the hardware
    /// there, so a line drawn on to the centre would spend the end of its
    /// run where nobody can see it, and the island would come loose a beat
    /// after the line appeared to finish. With the gap the two ends run into
    /// the sides of the housing and that is the finish.
    static func halves(of outline: CGPath, topGap: CGFloat = 0, flatness: CGFloat = 0.2) -> Halves? {
        let ring = longestRing(of: outline, flatness: flatness)
        let count = ring.count
        guard count >= 3 else { return nil }

        let box = outline.boundingBoxOfPath
        let midX = box.midX

        // Where the outline crosses its centre line. A side is "left of
        // centre" or not, so a vertex exactly on the line belongs to one
        // side and each crossing is counted once.
        var bottom: (segment: Int, point: CGPoint)?
        var top: (segment: Int, point: CGPoint)?
        for i in 0..<count {
            let a = ring[i], b = ring[(i + 1) % count]
            guard (a.x < midX) != (b.x < midX) else { continue }
            let f = (midX - a.x) / (b.x - a.x)
            let point = CGPoint(x: midX, y: a.y + (b.y - a.y) * f)
            if bottom == nil || point.y > bottom!.point.y { bottom = (i, point) }
            if top == nil || point.y < top!.point.y { top = (i, point) }
        }
        guard let bottom, let top, bottom.segment != top.segment else { return nil }

        // Round the ring both ways from the bottom crossing to the top one.
        var forward = [bottom.point]
        var i = (bottom.segment + 1) % count
        while true {
            forward.append(ring[i])
            if i == top.segment { break }
            i = (i + 1) % count
        }
        forward.append(top.point)

        var backward = [bottom.point]
        i = bottom.segment
        while true {
            backward.append(ring[i])
            if i == (top.segment + 1) % count { break }
            i = (i - 1 + count) % count
        }
        backward.append(top.point)

        // Which went left: the one whose points sit left of centre.
        let forwardIsLeft = meanX(forward) < meanX(backward)
        let left = stopShort(forwardIsLeft ? forward : backward, of: midX, by: topGap / 2)
        let right = stopShort(forwardIsLeft ? backward : forward, of: midX, by: topGap / 2)
        guard left.count >= 2, right.count >= 2 else { return nil }

        return Halves(
            left: polyline(left),
            right: polyline(right),
            start: bottom.point,
            leftEnd: left[left.count - 1],
            rightEnd: right[right.count - 1],
            leftLength: length(left),
            rightLength: length(right)
        )
    }

    // MARK: - Pieces

    /// The outline as a closed ring of points: its longest subpath,
    /// flattened, without the repeated points flattening leaves at joins.
    private static func longestRing(of path: CGPath, flatness: CGFloat) -> [CGPoint] {
        var rings: [[CGPoint]] = []
        var current: [CGPoint] = []
        func add(_ p: CGPoint) {
            if let last = current.last, hypot(last.x - p.x, last.y - p.y) < 0.001 { return }
            current.append(p)
        }
        path.flattened(threshold: flatness).applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if current.count >= 3 { rings.append(current) }
                current = [e.points[0]]
            case .addLineToPoint:
                add(e.points[0])
            case .closeSubpath:
                if current.count >= 3 { rings.append(current) }
                current = []
            // Flattened: no curves left.
            case .addQuadCurveToPoint: add(e.points[1])
            case .addCurveToPoint: add(e.points[2])
            @unknown default: break
            }
        }
        if current.count >= 3 { rings.append(current) }
        guard var ring = rings.max(by: { length($0, closed: true) < length($1, closed: true) }) else { return [] }
        // A ring that ends where it began: the closing segment is implied.
        if let first = ring.first, let last = ring.last, ring.count > 1,
           hypot(first.x - last.x, first.y - last.y) < 0.001 {
            ring.removeLast()
        }
        return ring
    }

    /// `chain` ended where it first comes within `half` of the centre line
    /// on its way to its end there. The whole chain if it never leaves that
    /// strip (a gap wider than the outline), or with no gap.
    private static func stopShort(_ chain: [CGPoint], of midX: CGFloat, by half: CGFloat) -> [CGPoint] {
        guard half > 0, chain.count >= 2 else { return chain }
        // Back from the end to the last point still outside the strip.
        var i = chain.count - 1
        while i >= 0, abs(chain[i].x - midX) <= half { i -= 1 }
        guard i >= 0, i < chain.count - 1 else { return chain }
        let outside = chain[i], inside = chain[i + 1]
        let edge = midX + (outside.x < midX ? -half : half)
        let f = (edge - outside.x) / (inside.x - outside.x)
        let end = CGPoint(x: edge, y: outside.y + (inside.y - outside.y) * f)
        return Array(chain[...i]) + [end]
    }

    private static func polyline(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        return path
    }

    private static func meanX(_ points: [CGPoint]) -> CGFloat {
        points.reduce(0) { $0 + $1.x } / CGFloat(max(points.count, 1))
    }

    private static func length(_ points: [CGPoint], closed: Bool = false) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<points.count {
            total += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        if closed, let first = points.first, let last = points.last {
            total += hypot(first.x - last.x, first.y - last.y)
        }
        return total
    }
}
