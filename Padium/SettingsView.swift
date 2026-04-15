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

    var body: some View {
        Form {
            if let notice = appState.systemGestureNotice {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
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

                Text("Higher sensitivity triggers all swipe gestures with shorter movement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.slots, id: \.self) { slot in
                        GestureRowView(slot: slot)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
