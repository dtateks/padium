import SwiftUI
import KeyboardShortcuts

struct GestureRowView: View {
    let slot: GestureSlot
    var isConflicting: Bool = false
    var onShortcutChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent {
                KeyboardShortcuts.Recorder(for: ShortcutRegistry.name(for: slot)) { _ in
                    onShortcutChange()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(slot.displayName)
                    if isConflicting {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                    }
                }
            }

            if isConflicting {
                Text("Conflicts with a macOS system gesture — both will fire")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}
