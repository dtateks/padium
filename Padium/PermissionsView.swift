import SwiftUI

struct PermissionsView: View {
    let permissionState: PermissionState
    let systemGestureNotice: String?
    let conflictingSettings: [SystemGestureSetting]
    let onRequestAccessibility: () -> Void
    let onOpenTrackpadSettings: () -> Void
    let onRefreshConflicts: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)

            switch permissionState {
            case .checking:
                Text("Checking permissions…")
                    .foregroundStyle(.secondary)

            case .granted:
                Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case .denied:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Accessibility", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("Required to emit keyboard shortcuts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Grant Accessibility Permission") {
                        onRequestAccessibility()
                    }
                    .buttonStyle(.link)
                }
            }

            Divider()

            systemGestureConflictSection
        }
        .padding()
        .frame(width: 360)
    }

    @ViewBuilder
    private var systemGestureConflictSection: some View {
        let enabledConflicts = conflictingSettings.filter(\.isEnabled)

        if enabledConflicts.isEmpty {
            Label("No system gesture conflicts", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("System gestures conflict with Padium")
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Text("These macOS gestures are enabled and will fire alongside Padium. Disable them in Trackpad settings:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(enabledConflicts) { setting in
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text(setting.title)
                            .font(.callout)
                    }
                }

                HStack {
                    Button("Open Trackpad Settings") {
                        onOpenTrackpadSettings()
                    }

                    Button("Refresh") {
                        onRefreshConflicts()
                    }
                }
            }
        }
    }
}
