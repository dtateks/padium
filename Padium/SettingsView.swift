import SwiftUI

struct SettingsView: View {
    let appState: AppState

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
