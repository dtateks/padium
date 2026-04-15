import SwiftUI
import KeyboardShortcuts

struct GestureRowView: View {
    let slot: GestureSlot
    var isConflicting: Bool = false
    var onShortcutChange: () -> Void = {}

    @State private var actionKind: GestureActionKind

    init(slot: GestureSlot, isConflicting: Bool = false, onShortcutChange: @escaping () -> Void = {}) {
        self.slot = slot
        self.isConflicting = isConflicting
        self.onShortcutChange = onShortcutChange
        _actionKind = State(initialValue: GestureActionStore.actionKind(for: slot))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if slot.supportsActionKindChoice {
                tapRow
            } else {
                shortcutRow
            }

            if isConflicting {
                Text("Conflicts with a macOS system gesture — both will fire")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var shortcutRow: some View {
        LabeledContent {
            KeyboardShortcuts.Recorder(for: ShortcutRegistry.name(for: slot)) { _ in
                onShortcutChange()
            }
        } label: {
            slotLabel
        }
    }

    private var tapRow: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Picker("", selection: $actionKind) {
                    Text("Shortcut").tag(GestureActionKind.shortcut)
                    Text("Middle Click").tag(GestureActionKind.middleClick)
                }
                .pickerStyle(.menu)
                .fixedSize()
                .onChange(of: actionKind) { _, newValue in
                    GestureActionStore.setActionKind(newValue, for: slot)
                    onShortcutChange()
                }

                if actionKind == .shortcut {
                    KeyboardShortcuts.Recorder(for: ShortcutRegistry.name(for: slot)) { _ in
                        onShortcutChange()
                    }
                }
            }
        } label: {
            slotLabel
        }
    }

    private var slotLabel: some View {
        HStack(spacing: 4) {
            Text(slot.displayName)
            if isConflicting {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption2)
            }
        }
    }
}
