import SwiftUI
import KeyboardShortcuts

struct GestureRowView: View {
    let slot: GestureSlot
    var isConflicting: Bool = false
    var onShortcutChange: () -> Void = {}

    // @AppStorage observes UserDefaults, so the picker reflects external
    // changes (e.g. other Padium features writing the same key) without
    // a stale snapshot from view init.
    @AppStorage private var storedActionKind: String

    init(slot: GestureSlot, isConflicting: Bool = false, onShortcutChange: @escaping () -> Void = {}) {
        self.slot = slot
        self.isConflicting = isConflicting
        self.onShortcutChange = onShortcutChange
        _storedActionKind = AppStorage(
            wrappedValue: GestureActionKind.shortcut.rawValue,
            GestureActionStore.userDefaultsKey(for: slot)
        )
    }

    private var actionKind: GestureActionKind {
        GestureActionKind(rawValue: storedActionKind) ?? .shortcut
    }

    private var actionKindBinding: Binding<GestureActionKind> {
        Binding(
            get: { actionKind },
            set: { newValue in
                GestureActionStore.setActionKind(newValue, for: slot)
                onShortcutChange()
            }
        )
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
            PadiumShortcutRecorder(for: slot) {
                onShortcutChange()
            }
        } label: {
            slotLabel
        }
    }

    private var tapRow: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Picker("", selection: actionKindBinding) {
                    Text("Shortcut").tag(GestureActionKind.shortcut)
                    Text("Middle Click").tag(GestureActionKind.middleClick)
                }
                .pickerStyle(.menu)
                .fixedSize()

                if actionKind == .shortcut {
                    PadiumShortcutRecorder(for: slot) {
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
