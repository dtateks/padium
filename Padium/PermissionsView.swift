import SwiftUI

struct PermissionsView: View {
    let permissionState: PermissionState
    let systemGestureNotice: String?
    let onRequestAccessibility: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions Required")
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
}
