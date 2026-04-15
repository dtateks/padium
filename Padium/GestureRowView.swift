import SwiftUI
import KeyboardShortcuts

struct GestureRowView: View {
    let slot: GestureSlot
    var isConflicting: Bool = false

    var onShortcutChange: () -> Void = {}
    @State private var lastKnownShortcut: KeyboardShortcuts.Shortcut?

    init(
        slot: GestureSlot,
        isConflicting: Bool = false,
        onShortcutChange: @escaping () -> Void = {}
    ) {
        self.slot = slot
        self.isConflicting = isConflicting
        self.onShortcutChange = onShortcutChange
        _lastKnownShortcut = State(initialValue: KeyboardShortcuts.getShortcut(for: ShortcutRegistry.name(for: slot)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent {
                KeyboardShortcuts.Recorder(for: ShortcutRegistry.name(for: slot))
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
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let currentShortcut = KeyboardShortcuts.getShortcut(for: ShortcutRegistry.name(for: slot))
            guard currentShortcut != lastKnownShortcut else { return }
            lastKnownShortcut = currentShortcut
            onShortcutChange()
        }
    }
}
