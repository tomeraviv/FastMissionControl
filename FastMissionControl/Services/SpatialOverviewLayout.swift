//
//  SpatialOverviewLayout.swift
//  FastMissionControl
//
//  Created by Codex.
//

import CoreGraphics

/// Lays out window thumbnails in a Mission-Control-style collage.
///
/// Windows are scaled down from their original positions, maintaining
/// spatial relationships (a window that was top-left stays top-left).
/// Overlaps are resolved iteratively by pushing windows apart.
/// Windows are never enlarged past their original size.
final class SpatialOverviewLayout {
    private let horizontalPadding: CGFloat = 48
    private let topPadding: CGFloat = 48
    private let bottomPadding: CGFloat = 130   // room for shelf row + dock
    private let titleBarGap: CGFloat = 6
    private let titleBarHeight: CGFloat = 40
    private let windowSpacing: CGFloat = 18    // minimum gap between windows
    private let overlapIterations = 50

    func apply(to snapshot: OverviewSnapshot) {
        let windowsByDisplay = Dictionary(grouping: snapshot.windows, by: \.displayID)

        for display in snapshot.displays {
            guard let windows = windowsByDisplay[display.id], !windows.isEmpty else {
                continue
            }

            let titleReserve = titleBarHeight + titleBarGap

            // Safe content area (padded, below title bars, above shelf/dock).
            let contentRect = CGRect(
                x: display.localFrame.minX + horizontalPadding,
                y: display.localFrame.minY + topPadding + titleReserve,
                width: display.localFrame.width - horizontalPadding * 2,
                height: max(100, display.localFrame.height - topPadding - bottomPadding - titleReserve)
            )

            layoutCollage(windows: windows, contentRect: contentRect, display: display)
        }
    }

    // MARK: - Collage layout

    private func layoutCollage(windows: [WindowDescriptor], contentRect: CGRect, display: DisplayOverview) {
        let n = windows.count

        // 1. Compute scale factor.
        //    Use area-based scaling: ensure total scaled window area is
        //    ~65% of the content area, so windows actually fit.
        let totalSourceArea = windows.reduce(CGFloat(0)) {
            $0 + $1.sourceFrame.width * $1.sourceFrame.height
        }
        let contentArea = contentRect.width * contentRect.height
        let packingEfficiency: CGFloat = 0.60
        let areaScale = sqrt(contentArea * packingEfficiency / max(totalSourceArea, 1))

        // Also ensure we don't exceed the sourceUnion → contentRect ratio.
        let sourceUnion = windows.reduce(CGRect.null) { $0.union($1.sourceFrame) }
        let unionScale: CGFloat
        if sourceUnion.width > 0 && sourceUnion.height > 0 {
            unionScale = min(
                contentRect.width / sourceUnion.width,
                contentRect.height / sourceUnion.height
            ) * 0.80
        } else {
            unionScale = 1.0
        }

        // Never enlarge past original size.
        let scale = min(areaScale, unionScale, 1.0)

        // 2. Map each window: shrink and reposition proportionally.
        var frames: [CGRect] = windows.map { w in
            let sw = w.sourceFrame.width * scale
            let sh = w.sourceFrame.height * scale

            // Map center proportionally from source space → content space.
            let relX: CGFloat
            let relY: CGFloat
            if sourceUnion.width > 1 {
                relX = (w.sourceFrame.midX - sourceUnion.minX) / sourceUnion.width
            } else {
                relX = 0.5
            }
            if sourceUnion.height > 1 {
                relY = (w.sourceFrame.midY - sourceUnion.minY) / sourceUnion.height
            } else {
                relY = 0.5
            }

            let cx = contentRect.minX + relX * contentRect.width
            let cy = contentRect.minY + relY * contentRect.height

            return CGRect(x: cx - sw / 2, y: cy - sh / 2, width: sw, height: sh)
        }

        // 3. Spread windows out if they're too clustered (e.g. stacked/maximized).
        spreadIfClustered(&frames, in: contentRect)
        reseedIfAxisCollapsed(&frames, in: contentRect)

        // 4. Resolve overlaps.
        resolveOverlaps(&frames, in: contentRect)

        // 5. Assign results.
        for (i, window) in windows.enumerated() {
            window.targetFrame = frames[i]
            window.titleBarFrame = CGRect(
                x: frames[i].minX,
                y: max(display.localFrame.minY + 8,
                     frames[i].minY - titleBarHeight - titleBarGap),
                width: frames[i].width,
                height: titleBarHeight
            )
        }
    }

    // MARK: - Spread clustered windows

    /// When windows are clustered near the center (e.g. all maximized),
    /// scale their offsets from the centroid to fill more of the content area.
    private func spreadIfClustered(_ frames: inout [CGRect], in bounds: CGRect) {
        let n = frames.count
        guard n > 1 else { return }

        let centers = frames.map { CGPoint(x: $0.midX, y: $0.midY) }
        let centroid = CGPoint(
            x: centers.map(\.x).reduce(0, +) / CGFloat(n),
            y: centers.map(\.y).reduce(0, +) / CGFloat(n)
        )

        let maxOffsetX = centers.map { abs($0.x - centroid.x) }.max() ?? 0
        let maxOffsetY = centers.map { abs($0.y - centroid.y) }.max() ?? 0

        // Desired spread: centers should span at least 20% of the bounds.
        let desiredSpreadX = bounds.width * 0.90
        let desiredSpreadY = bounds.height * 0.90

        let spreadX = maxOffsetX > 1 ? max(1.0, desiredSpreadX / maxOffsetX) : 1.0
        let spreadY = maxOffsetY > 1 ? max(1.0, desiredSpreadY / maxOffsetY) : 1.0

        for i in 0..<n {
            let cx = frames[i].midX
            let cy = frames[i].midY
            let newCX = centroid.x + (cx - centroid.x) * spreadX
            let newCY = centroid.y + (cy - centroid.y) * spreadY
            frames[i].origin.x = newCX - frames[i].width / 2
            frames[i].origin.y = newCY - frames[i].height / 2
        }
    }

    /// If windows collapse into a near-line (common when many start centered),
    /// reseed them into a loose grid so overlap resolution can preserve 2D spread.
    private func reseedIfAxisCollapsed(_ frames: inout [CGRect], in bounds: CGRect) {
        let n = frames.count
        guard n >= 3 else { return }

        let minCenterX = frames.map(\.midX).min() ?? 0
        let maxCenterX = frames.map(\.midX).max() ?? 0
        let minCenterY = frames.map(\.midY).min() ?? 0
        let maxCenterY = frames.map(\.midY).max() ?? 0
        let spanX = maxCenterX - minCenterX
        let spanY = maxCenterY - minCenterY

        let minSpanX = bounds.width * 0.22
        let minSpanY = bounds.height * 0.22

        guard spanX < minSpanX || spanY < minSpanY else { return }

        let sortedIndices = frames.indices.sorted { lhs, rhs in
            let leftY = frames[lhs].midY
            let rightY = frames[rhs].midY
            if abs(leftY - rightY) < 1 {
                return frames[lhs].midX < frames[rhs].midX
            }
            return leftY < rightY
        }

        let baseColumns = Int(ceil(sqrt(Double(n))))
        let columns = spanX < minSpanX ? max(2, baseColumns) : max(1, baseColumns)
        let rows = max(1, Int(ceil(Double(n) / Double(columns))))
        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = bounds.height / CGFloat(rows)

        for (slot, index) in sortedIndices.enumerated() {
            let row = slot / columns
            let column = slot % columns
            let centerX = bounds.minX + (CGFloat(column) + 0.5) * cellWidth
            let centerY = bounds.minY + (CGFloat(row) + 0.5) * cellHeight

            frames[index].origin.x = centerX - frames[index].width / 2
            frames[index].origin.y = centerY - frames[index].height / 2
            clampToBounds(&frames[index], in: bounds)
        }
    }

    // MARK: - Overlap resolution

    private func resolveOverlaps(_ frames: inout [CGRect], in bounds: CGRect) {
        let n = frames.count
        guard n > 1 else {
            // Single window: just clamp.
            if n == 1 { clampToBounds(&frames[0], in: bounds) }
            return
        }

        let pad = windowSpacing

        for _ in 0..<overlapIterations {
            var anyOverlap = false

            for i in 0..<n {
                for j in (i + 1)..<n {
                    // Inflate rects by half the spacing for minimum gap.
                    let a = frames[i].insetBy(dx: -pad / 2, dy: -pad / 2)
                    let b = frames[j].insetBy(dx: -pad / 2, dy: -pad / 2)

                    guard a.intersects(b) else { continue }
                    anyOverlap = true

                    let intersection = a.intersection(b)
                    let deltaX = frames[j].midX - frames[i].midX
                    let deltaY = frames[j].midY - frames[i].midY
                    let coincidentCenters = abs(deltaX) < 0.5 && abs(deltaY) < 0.5

                    // Push along the dominant center delta; when coincident, alternate axis
                    // so large stacks don't collapse into a single vertical column.
                    let pushHorizontally = coincidentCenters
                        ? ((i + j) % 2 == 0)
                        : abs(deltaX) >= abs(deltaY)

                    if pushHorizontally {
                        let push = intersection.width / 2 + 0.5
                        let dir: CGFloat
                        if abs(deltaX) >= 0.5 {
                            dir = deltaX > 0 ? -1 : 1
                        } else {
                            dir = ((i * 31 + j * 17) % 2 == 0) ? -1 : 1
                        }
                        frames[i].origin.x += dir * push
                        frames[j].origin.x -= dir * push
                    } else {
                        let push = intersection.height / 2 + 0.5
                        let dir: CGFloat
                        if abs(deltaY) >= 0.5 {
                            dir = deltaY > 0 ? -1 : 1
                        } else {
                            dir = ((i * 13 + j * 29) % 2 == 0) ? -1 : 1
                        }
                        frames[i].origin.y += dir * push
                        frames[j].origin.y -= dir * push
                    }
                }
            }

            // Clamp all to bounds.
            for i in 0..<n {
                clampToBounds(&frames[i], in: bounds)
            }

            if !anyOverlap { break }
        }
    }

    private func clampToBounds(_ frame: inout CGRect, in bounds: CGRect) {
        frame.origin.x = max(bounds.minX, min(frame.origin.x, bounds.maxX - frame.width))
        frame.origin.y = max(bounds.minY, min(frame.origin.y, bounds.maxY - frame.height))
    }
}
