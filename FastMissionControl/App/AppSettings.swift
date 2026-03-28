//
//  AppSettings.swift
//  FastMissionControl
//
//  Created by Codex.
//

import Foundation
import CoreGraphics
import Combine

struct SettingDefinition: Identifiable {
    enum Kind {
        case toggle(defaultValue: Bool)
        case integer(defaultValue: Int, range: ClosedRange<Int>, step: Int)
        case double(defaultValue: Double, range: ClosedRange<Double>, step: Double)
    }

    let key: AppSettings.Key
    let section: String
    let title: String
    let description: String
    let kind: Kind

    var id: AppSettings.Key {
        key
    }
}

final class AppSettings: ObservableObject {
    enum Key: String, CaseIterable, Identifiable {
        case toggleButtonNumber
        case prewarmIntervalSeconds
        case liveRefreshIntervalSeconds
        case livePreviewStartupDelaySeconds
        case openAnimationDurationSeconds
        case selectionAnimationDurationSeconds
        case slowOpenAnimationDurationSeconds
        case slowSelectionAnimationDurationSeconds
        case layoutHorizontalPadding
        case layoutTopPadding
        case layoutBottomPadding
        case layoutTitleBarGap
        case layoutTitleBarHeight
        case layoutBaseWindowSpacing
        case layoutOverlapIterations
        case layoutOverlapDensityGridThreshold
        case livePreviewBaseLimit
        case livePreviewPerExtraDisplayPenalty
        case livePreviewMinimumLimit
        case defaultLivePreviewIntervalSeconds
        case livePreviewMinIntervalSeconds
        case livePreviewMaxIntervalSeconds
        case suspendedPreviewIntervalSeconds
        case idlePreviewIntervalSeconds
        case livePreviewCaptureConcurrencyLimit

        var id: String {
            rawValue
        }
    }

    enum Value: Equatable {
        case bool(Bool)
        case int(Int)
        case double(Double)
    }

    static let definitions: [SettingDefinition] = [
        SettingDefinition(
            key: .toggleButtonNumber,
            section: "Trigger",
            title: "Toggle Button Number",
            description: "Zero-based mouse button number used to open the overview.",
            kind: .integer(defaultValue: 3, range: 2...8, step: 1)
        ),
        SettingDefinition(
            key: .prewarmIntervalSeconds,
            section: "Timing",
            title: "Prewarm Interval",
            description: "How often the app refreshes the cached still previews while idle.",
            kind: .double(defaultValue: 3.0, range: 0.5...30.0, step: 0.5)
        ),
        SettingDefinition(
            key: .liveRefreshIntervalSeconds,
            section: "Timing",
            title: "Live Inventory Refresh",
            description: "How often the app checks for newly opened or closed windows while the overview is visible.",
            kind: .double(defaultValue: 1.5, range: 0.25...10.0, step: 0.25)
        ),
        SettingDefinition(
            key: .livePreviewStartupDelaySeconds,
            section: "Timing",
            title: "Live Preview Startup Delay",
            description: "Delay before live previews begin after the overview opens.",
            kind: .double(defaultValue: 0.1, range: 0.0...2.0, step: 0.05)
        ),
        SettingDefinition(
            key: .openAnimationDurationSeconds,
            section: "Animation",
            title: "Open Duration",
            description: "Normal overview open animation duration.",
            kind: .double(defaultValue: 0.22, range: 0.05...2.0, step: 0.01)
        ),
        SettingDefinition(
            key: .selectionAnimationDurationSeconds,
            section: "Animation",
            title: "Selection Duration",
            description: "Normal dismiss animation duration when selecting a window.",
            kind: .double(defaultValue: 0.18, range: 0.05...2.0, step: 0.01)
        ),
        SettingDefinition(
            key: .slowOpenAnimationDurationSeconds,
            section: "Animation",
            title: "Slow Open Duration",
            description: "Overview open animation duration when Shift is held.",
            kind: .double(defaultValue: 0.75, range: 0.1...3.0, step: 0.05)
        ),
        SettingDefinition(
            key: .slowSelectionAnimationDurationSeconds,
            section: "Animation",
            title: "Slow Selection Duration",
            description: "Dismiss animation duration when Shift is held during selection.",
            kind: .double(defaultValue: 0.75, range: 0.1...3.0, step: 0.05)
        ),
        SettingDefinition(
            key: .layoutHorizontalPadding,
            section: "Layout",
            title: "Horizontal Padding",
            description: "Side padding applied to each display when placing thumbnails.",
            kind: .double(defaultValue: 48.0, range: 0.0...200.0, step: 1.0)
        ),
        SettingDefinition(
            key: .layoutTopPadding,
            section: "Layout",
            title: "Top Padding",
            description: "Top padding applied before window thumbnails are laid out.",
            kind: .double(defaultValue: 48.0, range: 0.0...200.0, step: 1.0)
        ),
        SettingDefinition(
            key: .layoutBottomPadding,
            section: "Layout",
            title: "Bottom Padding",
            description: "Bottom reserve for the shelf row and Dock.",
            kind: .double(defaultValue: 130.0, range: 0.0...320.0, step: 1.0)
        ),
        SettingDefinition(
            key: .layoutTitleBarGap,
            section: "Layout",
            title: "Title Bar Gap",
            description: "Gap between the title bar chip and the thumbnail body.",
            kind: .double(defaultValue: 6.0, range: 0.0...30.0, step: 1.0)
        ),
        SettingDefinition(
            key: .layoutTitleBarHeight,
            section: "Layout",
            title: "Title Bar Height",
            description: "Reserved height for the title chips drawn above each thumbnail.",
            kind: .double(defaultValue: 40.0, range: 20.0...90.0, step: 1.0)
        ),
        SettingDefinition(
            key: .layoutBaseWindowSpacing,
            section: "Layout",
            title: "Base Window Spacing",
            description: "Default thumbnail spacing before adaptive tightening kicks in.",
            kind: .double(defaultValue: 18.0, range: 0.0...60.0, step: 1.0)
        ),
        SettingDefinition(
            key: .layoutOverlapIterations,
            section: "Layout",
            title: "Overlap Iterations",
            description: "Maximum passes used to resolve thumbnail overlaps.",
            kind: .integer(defaultValue: 80, range: 1...200, step: 1)
        ),
        SettingDefinition(
            key: .layoutOverlapDensityGridThreshold,
            section: "Layout",
            title: "Grid Threshold",
            description: "Switches to grid packing once overlap density exceeds this value.",
            kind: .double(defaultValue: 1.3, range: 1.0...3.0, step: 0.05)
        ),
        SettingDefinition(
            key: .livePreviewBaseLimit,
            section: "Previews",
            title: "Base Live Preview Limit",
            description: "Starting budget for how many windows receive live previews.",
            kind: .integer(defaultValue: 14, range: 1...40, step: 1)
        ),
        SettingDefinition(
            key: .livePreviewPerExtraDisplayPenalty,
            section: "Previews",
            title: "Per-Display Penalty",
            description: "Live preview budget reduction for each additional display.",
            kind: .integer(defaultValue: 2, range: 0...10, step: 1)
        ),
        SettingDefinition(
            key: .livePreviewMinimumLimit,
            section: "Previews",
            title: "Minimum Live Preview Limit",
            description: "Lower bound for the live preview budget.",
            kind: .integer(defaultValue: 6, range: 1...20, step: 1)
        ),
        SettingDefinition(
            key: .defaultLivePreviewIntervalSeconds,
            section: "Previews",
            title: "Default Preview Interval",
            description: "Initial live preview cadence before the adaptive throttling logic reacts.",
            kind: .double(defaultValue: 0.05, range: 0.016...0.3, step: 0.001)
        ),
        SettingDefinition(
            key: .livePreviewMinIntervalSeconds,
            section: "Previews",
            title: "Minimum Preview Interval",
            description: "Fastest allowed live preview cadence.",
            kind: .double(defaultValue: 0.033, range: 0.016...0.3, step: 0.001)
        ),
        SettingDefinition(
            key: .livePreviewMaxIntervalSeconds,
            section: "Previews",
            title: "Maximum Preview Interval",
            description: "Slowest allowed live preview cadence under pressure.",
            kind: .double(defaultValue: 0.18, range: 0.05...1.0, step: 0.005)
        ),
        SettingDefinition(
            key: .suspendedPreviewIntervalSeconds,
            section: "Previews",
            title: "Suspended Preview Interval",
            description: "Polling cadence while dragging or when preview updates are suspended.",
            kind: .double(defaultValue: 0.09, range: 0.01...0.5, step: 0.005)
        ),
        SettingDefinition(
            key: .idlePreviewIntervalSeconds,
            section: "Previews",
            title: "Idle Preview Interval",
            description: "Polling cadence when no windows are eligible for a live preview frame.",
            kind: .double(defaultValue: 0.12, range: 0.01...1.0, step: 0.005)
        ),
        SettingDefinition(
            key: .livePreviewCaptureConcurrencyLimit,
            section: "Previews",
            title: "Capture Concurrency",
            description: "Maximum number of parallel ScreenCaptureKit captures.",
            kind: .integer(defaultValue: 3, range: 1...8, step: 1)
        )
    ]

    private var values: [Key: Value]
    @Published private(set) var changeCounter = 0

    private let defaults: UserDefaults
    private let definitionsByKey: [Key: SettingDefinition]
    let sections: [String]
    private let definitionsBySection: [String: [SettingDefinition]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.definitionsByKey = Dictionary(uniqueKeysWithValues: Self.definitions.map { ($0.key, $0) })
        var orderedSections: [String] = []
        var sectionDefinitions: [String: [SettingDefinition]] = [:]
        for definition in Self.definitions {
            if sectionDefinitions[definition.section] == nil {
                orderedSections.append(definition.section)
            }
            sectionDefinitions[definition.section, default: []].append(definition)
        }
        self.sections = orderedSections
        self.definitionsBySection = sectionDefinitions
        self.values = [:]

        for definition in Self.definitions {
            values[definition.key] = Self.loadValue(for: definition, from: defaults)
        }
    }

    func definitions(in section: String) -> [SettingDefinition] {
        definitionsBySection[section] ?? []
    }

    func bool(_ key: Key) -> Bool {
        guard case let .bool(value) = value(for: key) else {
            fatalError("Setting \(key.rawValue) is not a Bool.")
        }
        return value
    }

    func int(_ key: Key) -> Int {
        guard case let .int(value) = value(for: key) else {
            fatalError("Setting \(key.rawValue) is not an Int.")
        }
        return value
    }

    func double(_ key: Key) -> Double {
        guard case let .double(value) = value(for: key) else {
            fatalError("Setting \(key.rawValue) is not a Double.")
        }
        return value
    }

    func set(_ newValue: Bool, for key: Key) {
        setValue(.bool(newValue), for: key)
    }

    func set(_ newValue: Int, for key: Key) {
        setValue(.int(newValue), for: key)
    }

    func set(_ newValue: Double, for key: Key) {
        setValue(.double(newValue), for: key)
    }

    var toggleButtonNumber: Int {
        int(.toggleButtonNumber)
    }

    var prewarmIntervalNanoseconds: UInt64 {
        nanoseconds(for: .prewarmIntervalSeconds)
    }

    var liveRefreshInterval: TimeInterval {
        double(.liveRefreshIntervalSeconds)
    }

    var livePreviewStartupDelayNanoseconds: UInt64 {
        nanoseconds(for: .livePreviewStartupDelaySeconds)
    }

    var openAnimationDuration: CFTimeInterval {
        double(.openAnimationDurationSeconds)
    }

    var selectionAnimationDuration: CFTimeInterval {
        double(.selectionAnimationDurationSeconds)
    }

    var slowOpenAnimationDuration: CFTimeInterval {
        double(.slowOpenAnimationDurationSeconds)
    }

    var slowSelectionAnimationDuration: CFTimeInterval {
        double(.slowSelectionAnimationDurationSeconds)
    }

    var openAnimationDurationNanoseconds: UInt64 {
        nanoseconds(for: .openAnimationDurationSeconds)
    }

    var selectionAnimationDurationNanoseconds: UInt64 {
        nanoseconds(for: .selectionAnimationDurationSeconds)
    }

    var slowOpenAnimationDurationNanoseconds: UInt64 {
        nanoseconds(for: .slowOpenAnimationDurationSeconds)
    }

    var slowSelectionAnimationDurationNanoseconds: UInt64 {
        nanoseconds(for: .slowSelectionAnimationDurationSeconds)
    }

    var layoutHorizontalPadding: CGFloat {
        CGFloat(double(.layoutHorizontalPadding))
    }

    var layoutTopPadding: CGFloat {
        CGFloat(double(.layoutTopPadding))
    }

    var layoutBottomPadding: CGFloat {
        CGFloat(double(.layoutBottomPadding))
    }

    var layoutTitleBarGap: CGFloat {
        CGFloat(double(.layoutTitleBarGap))
    }

    var layoutTitleBarHeight: CGFloat {
        CGFloat(double(.layoutTitleBarHeight))
    }

    var layoutBaseWindowSpacing: CGFloat {
        CGFloat(double(.layoutBaseWindowSpacing))
    }

    var layoutOverlapIterations: Int {
        int(.layoutOverlapIterations)
    }

    var layoutOverlapDensityGridThreshold: CGFloat {
        CGFloat(double(.layoutOverlapDensityGridThreshold))
    }

    var livePreviewBaseLimit: Int {
        int(.livePreviewBaseLimit)
    }

    var livePreviewPerExtraDisplayPenalty: Int {
        int(.livePreviewPerExtraDisplayPenalty)
    }

    var livePreviewMinimumLimit: Int {
        int(.livePreviewMinimumLimit)
    }

    var defaultLivePreviewIntervalNanoseconds: UInt64 {
        nanoseconds(for: .defaultLivePreviewIntervalSeconds)
    }

    var livePreviewMinIntervalNanoseconds: UInt64 {
        nanoseconds(for: .livePreviewMinIntervalSeconds)
    }

    var livePreviewMaxIntervalNanoseconds: UInt64 {
        nanoseconds(for: .livePreviewMaxIntervalSeconds)
    }

    var suspendedPreviewIntervalNanoseconds: UInt64 {
        nanoseconds(for: .suspendedPreviewIntervalSeconds)
    }

    var idlePreviewIntervalNanoseconds: UInt64 {
        nanoseconds(for: .idlePreviewIntervalSeconds)
    }

    var livePreviewCaptureConcurrencyLimit: Int {
        int(.livePreviewCaptureConcurrencyLimit)
    }

    private func value(for key: Key) -> Value {
        guard let value = values[key] else {
            fatalError("Missing setting for key \(key.rawValue).")
        }
        return value
    }

    private func setValue(_ newValue: Value, for key: Key) {
        guard values[key] != newValue else {
            return
        }

        objectWillChange.send()
        values[key] = newValue
        persist(newValue, for: key)
        changeCounter += 1
    }

    private func persist(_ value: Value, for key: Key) {
        switch value {
        case let .bool(boolValue):
            defaults.set(boolValue, forKey: key.rawValue)
        case let .int(intValue):
            defaults.set(intValue, forKey: key.rawValue)
        case let .double(doubleValue):
            defaults.set(doubleValue, forKey: key.rawValue)
        }
    }

    private func nanoseconds(for key: Key) -> UInt64 {
        UInt64(max(0, double(key)) * 1_000_000_000)
    }

    private static func loadValue(for definition: SettingDefinition, from defaults: UserDefaults) -> Value {
        let key = definition.key.rawValue
        switch definition.kind {
        case let .toggle(defaultValue):
            if defaults.object(forKey: key) == nil {
                return .bool(defaultValue)
            }
            return .bool(defaults.bool(forKey: key))
        case let .integer(defaultValue, range, _):
            if defaults.object(forKey: key) == nil {
                return .int(defaultValue)
            }
            let value = defaults.integer(forKey: key)
            return .int(min(max(value, range.lowerBound), range.upperBound))
        case let .double(defaultValue, range, _):
            if defaults.object(forKey: key) == nil {
                return .double(defaultValue)
            }
            let value = defaults.double(forKey: key)
            return .double(min(max(value, range.lowerBound), range.upperBound))
        }
    }
}
