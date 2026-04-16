import SwiftUI

struct SettingsView: View {
    let appState: AppState

    private var sensitivityBinding: Binding<Double> {
        Binding(
            get: { appState.gestureSensitivity },
            set: { appState.setGestureSensitivity($0) }
        )
    }

    private var sections: [(title: String, slots: [GestureSlot])] {
        let supportedSlots = appState.supportedGestureSlots
        let grouped = Dictionary(grouping: supportedSlots, by: \.sectionTitle)
        var order: [String] = []
        for slot in supportedSlots where !order.contains(slot.sectionTitle) {
            order.append(slot.sectionTitle)
        }
        return order.compactMap { title in
            grouped[title].map { (title: title, slots: $0) }
        }
    }

    private var showsExperimentalTapNotice: Bool {
        appState.supportedGestureSlots.contains(where: \.isTapGesture)
    }

    var body: some View {
        Form {
            if let notice = appState.systemGestureNotice {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)

                        HStack {
                            Button("Open Trackpad Settings") {
                                appState.openTrackpadSettings()
                            }
                            Button("Refresh") {
                                appState.refreshSystemGestureConflicts()
                            }
                        }
                        .font(.callout)
                    }
                }
            }

            Section("Sensitivity") {
                HStack {
                    Text("Shared sensitivity")
                    Spacer()
                    Text("\(Int(appState.gestureSensitivity * 100))%")
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: sensitivityBinding,
                    in: GestureSensitivitySetting.minimumValue...GestureSensitivitySetting.maximumValue
                )

                Text("Higher sensitivity triggers swipe gestures with shorter movement. Tap gestures use fixed timing and movement thresholds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if showsExperimentalTapNotice {
                Section {
                    Label("Experimental tap gestures can overlap with macOS Smart Zoom, Look Up, Mission Control, App Exposé, or Show Desktop depending on your trackpad settings.", systemImage: "flask")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.slots, id: \.self) { slot in
                        GestureRowView(
                            slot: slot,
                            isConflicting: appState.conflictingSlots.contains(slot),
                            onShortcutChange: appState.handleShortcutConfigurationChange
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
