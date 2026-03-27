//
//  ContentView.swift
//  FastMissionControl
//
//  Created by Codex.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Fast Mission Control")
                    .font(.system(size: 24, weight: .bold))
                Text("Mouse button 4 toggles the overview.")
                    .font(.system(size: 13, weight: .medium))
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
                }
                .font(.system(size: 13))
            } label: {
                Text("State")
                    .font(.system(size: 13, weight: .semibold))
            }

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
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 430, minHeight: 360)
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

#Preview {
    ContentView(model: AppModel())
}
