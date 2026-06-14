//
//  AXWindowMatcher.swift
//  FastMissionControl
//
//  Created by Codex.
//

import CoreGraphics
import ScreenCaptureKit

final class AXWindowMatcher {
    func match(shareableWindow: SCWindow, appKitBounds: CGRect, candidates: [AXWindowHandle]) -> AXWindowHandle? {
        match(title: shareableWindow.title, appKitBounds: appKitBounds, candidates: candidates)
    }

    func match(title: String?, appKitBounds: CGRect, candidates: [AXWindowHandle]) -> AXWindowHandle? {
        let targetTitle = normalized(title)

        let best = candidates
            .filter { !$0.isMinimized }
            .map { candidate in
                (candidate, score(targetTitle: targetTitle, targetFrame: appKitBounds, candidate: candidate))
            }
            .max { lhs, rhs in
                lhs.1 < rhs.1
            }

        guard let best, best.1 > 50 else {
            return nil
        }

        return best.0
    }

    func safeMatch(
        title: String?,
        appKitBounds: CGRect,
        candidates: [AXWindowHandle],
        maximumDistance: CGFloat = 120,
        ambiguityMargin: CGFloat = 24
    ) -> AXWindowHandle? {
        let targetTitle = normalized(title)
        let matches = candidates.compactMap { candidate -> (handle: AXWindowHandle, distance: CGFloat)? in
            guard !candidate.isMinimized,
                  normalized(candidate.title) == targetTitle else {
                return nil
            }

            let frame = candidate.frame
            let frameDistance = [
                abs(frame.minX - appKitBounds.minX),
                abs(frame.minY - appKitBounds.minY),
                abs(frame.width - appKitBounds.width),
                abs(frame.height - appKitBounds.height)
            ].max() ?? .greatestFiniteMagnitude

            return (candidate, frameDistance)
        }
        .sorted { $0.distance < $1.distance }

        guard let best = matches.first, best.distance <= maximumDistance else { return nil }
        if matches.count > 1, matches[1].distance - best.distance < ambiguityMargin {
            return nil
        }

        return best.handle
    }

    private func score(targetTitle: String?, targetFrame: CGRect, candidate: AXWindowHandle) -> CGFloat {
        var total: CGFloat = 0

        let candidateTitle = normalized(candidate.title)
        if let targetTitle, !targetTitle.isEmpty {
            if targetTitle == candidateTitle {
                total += 150
            } else if let candidateTitle,
                      candidateTitle.contains(targetTitle) || targetTitle.contains(candidateTitle) {
                total += 60
            } else {
                total -= 35
            }
        }

        let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        let candidateCenter = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
        let distance = hypot(targetCenter.x - candidateCenter.x, targetCenter.y - candidateCenter.y)
        total += max(0, 120 - (distance * 1.2))

        let widthDelta = abs(targetFrame.width - candidate.frame.width)
        let heightDelta = abs(targetFrame.height - candidate.frame.height)
        total += max(0, 90 - (widthDelta + heightDelta))

        return total
    }

    private func normalized(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }
}
