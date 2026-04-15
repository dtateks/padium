import SwiftUI

struct PermissionsView: View {
    let permissionState: PermissionState
    let systemGestureNotice: String?
    let onOpenAccessibility: () -> Void
    let onOpenInputMonitoring: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions Required")
                .font(.headline)

            switch permissionState {
            case .checking:
                Text("Checking permissions…")
                    .foregroundStyle(.secondary)

            case .granted:
                Label("All permissions granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case let .denied(accessibility, inputMonitoring):
                if !accessibility {
                    permissionRow(
                        title: "Accessibility",
                        description: "Required to emit keyboard shortcuts.",
                        action: "Open Accessibility Settings",
                        onAction: onOpenAccessibility
                    )
                }

                if !inputMonitoring {
                    permissionRow(
                        title: "Input Monitoring",
                        description: "Required to read trackpad gestures.",
                        action: "Open Input Monitoring Settings",
                        onAction: onOpenInputMonitoring
                    )
                }
            }

            if let notice = systemGestureNotice {
                Divider()
                Label {
                    Text(notice)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
        .frame(width: 360)
    }

    private func permissionRow(title: String, description: String, action: String, onAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action) { onAction() }
                .buttonStyle(.link)
        }
    }
}
