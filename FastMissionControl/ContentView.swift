//
//  ContentView.swift
//  FastMissionControl
//
//  Created by Codex.
//

import SwiftUI
import Foundation

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fast Mission Control")
                        .font(.system(size: 24, weight: .bold))
                    Text("Mouse button \(settings.toggleButtonNumber + 1) toggles the overview.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(Self.buildTimestampLabel)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        PermissionRow(
                            title: "Screen Recording",
                            isGranted: model.permissions.screenRecordingGranted,
                            buttonTitle: "Request",
                            action: model.requestScreenRecording
                        )
                        PermissionRow(
                            title: "Accessibility",
                            isGranted: model.permissions.accessibilityGranted,
                            buttonTitle: "Request",
                            action: model.requestAccessibility
                        )
                    }
                    .padding(.vertical, 6)
                } label: {
                    Text("Permissions")
                        .font(.system(size: 13, weight: .semibold))
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Overview") {
                            Text(model.isOverviewVisible ? "Open" : "Closed")
                        }
                        LabeledContent("Status") {
                            Text(model.lastStatus)
                                .multilineTextAlignment(.trailing)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Latest Open Timings")
                                Spacer()
                                Text(model.latestOverviewOpenMetrics.triggerDescription)
                                    .foregroundStyle(.secondary)
                            }

                            if model.latestOverviewOpenMetrics.entries.isEmpty {
                                Text("Open the overview to record timings.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(model.latestOverviewOpenMetrics.entries) { entry in
                                    LabeledContent(entry.label) {
                                        Text(Self.formatTiming(entry.milliseconds))
                                            .monospacedDigit()
                                            .foregroundStyle(entry.milliseconds == nil ? .secondary : .primary)
                                    }
                                }
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Latest Close Timings")
                                Spacer()
                                Text(model.latestOverviewCloseMetrics.triggerDescription)
                                    .foregroundStyle(.secondary)
                            }

                            if model.latestOverviewCloseMetrics.entries.isEmpty {
                                Text("Close the overview to record timings.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(model.latestOverviewCloseMetrics.entries) { entry in
                                    LabeledContent(entry.label) {
                                        Text(Self.formatTiming(entry.milliseconds))
                                            .monospacedDigit()
                                            .foregroundStyle(entry.milliseconds == nil ? .secondary : .primary)
                                    }
                                }
                            }
                        }
                    }
                    .font(.system(size: 13))
                } label: {
                    Text("State")
                        .font(.system(size: 13, weight: .semibold))
                }

                SettingsBox(settings: model.settings)

                HStack(spacing: 12) {
                    Button(model.isOverviewVisible ? "Close Overview" : "Open Overview") {
                        model.toggleOverview()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.permissions.isReady)

                    Button("Refresh Permissions") {
                        model.refreshPermissions()
                    }
                    .buttonStyle(.bordered)

                    Button("Hide") {
                        model.hideControlWindow()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 640, minHeight: 720)
    }

    private static func formatTiming(_ milliseconds: Double?) -> String {
        guard let milliseconds else {
            return "pending"
        }

        return String(format: "%.2f ms", milliseconds)
    }

    private static var buildTimestampLabel: String {
        guard let executableURL = Bundle.main.executableURL,
              let values = try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]),
              let buildDate = values.contentModificationDate else {
            return "Build: unavailable"
        }

        return "Build: \(buildTimestampFormatter.string(from: buildDate))"
    }

    private static let buildTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct SettingsBox: View {
    @ObservedObject var settings: AppSettings
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                        .foregroundStyle(.secondary)
                    Text("Settings")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(settings.sections.enumerated()), id: \.element) { index, section in
                        if index > 0 {
                            Divider()
                                .padding(.horizontal, 12)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .tracking(0.5)

                            ForEach(settings.definitions(in: section)) { definition in
                                SettingControlRow(settings: settings, definition: definition)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                    }
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingControlRow: View {
    @ObservedObject var settings: AppSettings
    let definition: SettingDefinition

    var body: some View {
        switch definition.kind {
        case .toggle:
            Toggle(isOn: boolBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(definition.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(definition.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        case let .integer(_, range, step):
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(definition.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(definition.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Text("\(settings.int(definition.key))")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .frame(minWidth: 32, alignment: .trailing)
                        .monospacedDigit()

                    Stepper("", value: intBinding, in: range, step: step)
                        .labelsHidden()
                }
            }
        case let .double(_, range, step):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(definition.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(definition.description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(Self.formatted(settings.double(definition.key), step: step))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .frame(minWidth: 74, alignment: .trailing)
                }

                Slider(value: doubleBinding, in: range, step: step)
            }
        }
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { settings.bool(definition.key) },
            set: { settings.set($0, for: definition.key) }
        )
    }

    private var intBinding: Binding<Int> {
        Binding(
            get: { settings.int(definition.key) },
            set: { settings.set($0, for: definition.key) }
        )
    }

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { settings.double(definition.key) },
            set: { settings.set($0, for: definition.key) }
        )
    }

    private static func formatted(_ value: Double, step: Double) -> String {
        let decimals: Int
        if step < 0.01 {
            decimals = 3
        } else if step < 1 {
            decimals = 2
        } else {
            decimals = 0
        }

        return String(format: "%.\(decimals)f", value)
    }
}

private struct PermissionRow: View {
    let title: String
    let isGranted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(isGranted ? "Granted" : "Missing")
                    .font(.system(size: 12))
                    .foregroundStyle(isGranted ? .green : .secondary)
            }

            Spacer()

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .disabled(isGranted)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(model: AppModel(settings: AppSettings()))
    }
}
