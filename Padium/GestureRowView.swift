import SwiftUI
import KeyboardShortcuts

struct GestureRowView: View {
    let slot: GestureSlot

    var body: some View {
        LabeledContent(slot.displayName) {
            KeyboardShortcuts.Recorder(for: ShortcutRegistry.name(for: slot))
        }
    }
}
