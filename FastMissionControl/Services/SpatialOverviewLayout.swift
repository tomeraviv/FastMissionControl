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
    /// Default gap at low window counts; `adaptiveSpacing` tightens for denser grids.
    private let baseWindowSpacing: CGFloat = 18
    private let overlapIterations = 80
    /// When total source area is this much larger than the union bounding box,
    /// windows overlap heavily in screen space — use grid packing instead of
    /// proportional mapping + overlap push (which bunches large thumbnails).
    private let overlapDensityGridThreshold: CGFloat = 1.3

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
        let gap = adaptiveSpacing(windowCount: n)

        let sourceUnion = windows.reduce(CGRect.null) { $0.union($1.sourceFrame) }
        let totalSourceArea = windows.reduce(CGFloat(0)) {
            $0 + $1.sourceFrame.width * $1.sourceFrame.height
        }
        let unionArea = max(sourceUnion.width * sourceUnion.height, 1)
        let overlapDensity = totalSourceArea / unionArea

        if n > 1, overlapDensity > overlapDensityGridThreshold {
            layoutUniformGrid(windows: windows, contentRect: contentRect, display: display, gap: gap)
            return
        }

        // 1. Compute scale factor.
        //    Use area-based scaling: ensure total scaled window area is
        //    ~65% of the content area, so windows actually fit.
        let contentArea = contentRect.width * contentRect.height
        let packingEfficiency: CGFloat = 0.60
        let areaScale = sqrt(contentArea * packingEfficiency / max(totalSourceArea, 1))

        // Also ensure we don't exceed the sourceUnion → contentRect ratio.
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
        resolveOverlaps(&frames, in: contentRect, gap: gap)

        // 5. Assign results.
        assignFrames(frames, windows: windows, display: display)
    }

    // MARK: - Uniform grid (heavy overlap)

    /// Mission Control–style packing when many windows occupy the same screen region:
    /// one scale chosen so every thumbnail fits its grid cell, then centered — avoids
    /// overlap-resolution bunching from thumbnails larger than the reseed cells.
    private func layoutUniformGrid(
        windows: [WindowDescriptor],
        contentRect: CGRect,
        display: DisplayOverview,
        gap: CGFloat
    ) {
        let n = windows.count
        let grid = bestGrid(for: windows, in: contentRect, gap: gap)
        let columns = grid.columns
        let rows = grid.rows
        let safeCellW = grid.cellWidth
        let safeCellH = grid.cellHeight

        let sortedIndices = windows.indices.sorted { lhs, rhs in
            let a = windows[lhs].sourceFrame
            let b = windows[rhs].sourceFrame
            if abs(a.midY - b.midY) < 2 {
                return a.midX < b.midX
            }
            return a.midY < b.midY
        }

        var frames = [CGRect](repeating: .zero, count: n)
        let totalGridHeight = CGFloat(rows) * safeCellH + CGFloat(max(rows - 1, 0)) * gap
        let gridStartY = contentRect.midY - totalGridHeight / 2

        for (slot, index) in sortedIndices.enumerated() {
            let row = slot / columns
            let column = slot % columns
            let rowCount = min(columns, n - row * columns)
            let rowWidth = CGFloat(rowCount) * safeCellW + CGFloat(max(rowCount - 1, 0)) * gap
            let rowStartX = contentRect.midX - rowWidth / 2
            let cellMinX = rowStartX + CGFloat(column) * (safeCellW + gap)
            let cellMinY = gridStartY + CGFloat(row) * (safeCellH + gap)
            let cellCenter = CGPoint(
                x: cellMinX + safeCellW / 2,
                y: cellMinY + safeCellH / 2
            )
            let w = windows[index]
            let sw = max(w.sourceFrame.width, 1)
            let sh = max(w.sourceFrame.height, 1)
            let perWindowScale = min(safeCellW / sw, safeCellH / sh, 1.0)
            let fw = sw * perWindowScale
            let fh = sh * perWindowScale
            frames[index] = CGRect(
                x: cellCenter.x - fw / 2,
                y: cellCenter.y - fh / 2,
                width: fw,
                height: fh
            )
        }

        for i in 0..<n {
            clampToBounds(&frames[i], in: contentRect)
        }

        assignFrames(frames, windows: windows, display: display)
    }

    private func bestGrid(
        for windows: [WindowDescriptor],
        in contentRect: CGRect,
        gap: CGFloat
    ) -> (columns: Int, rows: Int, cellWidth: CGFloat, cellHeight: CGFloat) {
        let n = windows.count
        guard n > 0 else { return (1, 1, max(1, contentRect.width), max(1, contentRect.height)) }

        var best: (columns: Int, rows: Int, cellWidth: CGFloat, cellHeight: CGFloat, score: CGFloat)?

        for columns in 1...n {
            let rows = max(1, Int(ceil(CGFloat(n) / CGFloat(columns))))
            let availableW = contentRect.width - CGFloat(max(columns - 1, 0)) * gap
            let availableH = contentRect.height - CGFloat(max(rows - 1, 0)) * gap
            guard availableW > 8, availableH > 8 else { continue }

            let cellW = availableW / CGFloat(columns)
            let cellH = availableH / CGFloat(rows)

            var usedArea: CGFloat = 0
            for w in windows {
                let sw = max(w.sourceFrame.width, 1)
                let sh = max(w.sourceFrame.height, 1)
                let scale = min(cellW / sw, cellH / sh, 1.0)
                usedArea += (sw * scale) * (sh * scale)
            }

            let fillRatio = usedArea / max(contentRect.width * contentRect.height, 1)
            let rowBalance = CGFloat(min(columns, n)) / CGFloat(max(rows, 1))
            let targetBalance = contentRect.width / max(contentRect.height, 1)
            let balancePenalty = abs(log(max(rowBalance, 0.01) / max(targetBalance, 0.01)))
            let score = fillRatio - balancePenalty * 0.06

            if let currentBest = best {
                if score > currentBest.score {
                    best = (columns, rows, cellW, cellH, score)
                }
            } else {
                best = (columns, rows, cellW, cellH, score)
            }
        }

        if let best {
            return (best.columns, best.rows, best.cellWidth, best.cellHeight)
        }

        let fallbackColumns = Int(ceil(sqrt(Double(n))))
        let fallbackRows = max(1, Int(ceil(Double(n) / Double(fallbackColumns))))
        let fallbackCellW = max(1, (contentRect.width - CGFloat(max(fallbackColumns - 1, 0)) * gap) / CGFloat(fallbackColumns))
        let fallbackCellH = max(1, (contentRect.height - CGFloat(max(fallbackRows - 1, 0)) * gap) / CGFloat(fallbackRows))
        return (fallbackColumns, fallbackRows, fallbackCellW, fallbackCellH)
    }

    /// Tighter gaps as window count grows (Apple’s Mission Control gets denser at 12+ windows).
    private func adaptiveSpacing(windowCount: Int) -> CGFloat {
        let minGap: CGFloat = 8
        guard windowCount > 1 else { return baseWindowSpacing }
        let n = CGFloat(windowCount)
        // Gentle taper 2…8, steeper from 9…15, floor for very large sets.
        let taper: CGFloat
        if windowCount <= 8 {
            taper = 0.35
        } else if windowCount <= 15 {
            taper = 0.55
        } else {
            taper = 0.75
        }
        let excess = n - 2
        return max(minGap, baseWindowSpacing - excess * taper)
    }

    private func assignFrames(
        _ frames: [CGRect],
        windows: [WindowDescriptor],
        display: DisplayOverview
    ) {
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

    private func resolveOverlaps(_ frames: inout [CGRect], in bounds: CGRect, gap: CGFloat) {
        let n = frames.count
        guard n > 1 else {
            // Single window: just clamp.
            if n == 1 { clampToBounds(&frames[0], in: bounds) }
            return
        }

        let pad = gap

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
