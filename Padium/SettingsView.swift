import SwiftUI

struct SettingsContentView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PADIUM")
                        .font(.system(size: 20, weight: .heavy, design: .monospaced))
                        .tracking(2)
                    Text("TRACKPAD GESTURES TO SHORTCUTS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                
                Spacer()
                
                if appState.permissionState == .granted && appState.conflictingSlots.isEmpty {
                    statusBadge(title: "ACTIVE", color: .green)
                } else if appState.permissionState == .denied {
                    statusBadge(title: "AX DENIED", color: .red)
                } else {
                    statusBadge(title: "CONFLICTS", color: .orange)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            if appState.permissionState == .denied {
                permissionRequiredView
            } else {
                gestureConfigurationView
            }

            Divider()

            // Footer
            HStack {
                Text("SENSITIVITY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                Slider(
                    value: Binding(
                        get: { appState.gestureSensitivity },
                        set: { appState.setGestureSensitivity($0) }
                    ),
                    in: GestureSensitivitySetting.minimumValue...GestureSensitivitySetting.maximumValue
                )
                .frame(width: 120)
                .controlSize(.small)
                
                Spacer()

                if appState.systemGestureNotice != nil {
                    Button("FIX SYSTEM CONFLICTS") {
                        appState.openTrackpadSettings()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.trailing, 12)
                }

                Button("QUIT") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        }
        .frame(width: 740, height: 480)
        .onAppear {
            appState.setAppInteractionActive(true)
            appState.refreshPermissions()
        }
        .onDisappear {
            appState.setAppInteractionActive(false)
        }
    }
    
    private func statusBadge(title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var permissionRequiredView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.red.opacity(0.8))
            
            Text("ACCESSIBILITY REQUIRED")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
            
            Text("Padium needs Accessibility permission to simulate\nkeyboard shortcuts and intercept trackpad events.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Grant Permission") {
                appState.requestAccessibility()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var gestureConfigurationView: some View {
        HStack(spacing: 0) {
            // Swipes (Left half)
            VStack(alignment: .leading, spacing: 0) {
                headerText("SWIPES")
                
                VStack(spacing: 1) {
                    sectionHeader("3 FINGERS")
                    CompactGestureRow(slot: .threeFingerSwipeUp, appState: appState)
                    CompactGestureRow(slot: .threeFingerSwipeDown, appState: appState)
                    CompactGestureRow(slot: .threeFingerSwipeLeft, appState: appState)
                    CompactGestureRow(slot: .threeFingerSwipeRight, appState: appState)
                }
                .padding(.bottom, 12)
                
                VStack(spacing: 1) {
                    sectionHeader("4 FINGERS")
                    CompactGestureRow(slot: .fourFingerSwipeUp, appState: appState)
                    CompactGestureRow(slot: .fourFingerSwipeDown, appState: appState)
                    CompactGestureRow(slot: .fourFingerSwipeLeft, appState: appState)
                    CompactGestureRow(slot: .fourFingerSwipeRight, appState: appState)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Divider()
            
            // Taps (Right half)
            VStack(alignment: .leading, spacing: 0) {
                headerText("TAPS & CLICKS")
                
                VStack(spacing: 1) {
                    sectionHeader("1 & 2 FINGERS")
                    CompactGestureRow(slot: .oneFingerDoubleTap, appState: appState)
                    CompactGestureRow(slot: .twoFingerDoubleTap, appState: appState)
                }
                .padding(.bottom, 12)
                
                VStack(spacing: 1) {
                    sectionHeader("3 FINGERS")
                    CompactGestureRow(slot: .threeFingerDoubleTap, appState: appState)
                    CompactGestureRow(slot: .threeFingerClick, appState: appState)
                    CompactGestureRow(slot: .threeFingerDoubleClick, appState: appState)
                }
                .padding(.bottom, 12)
                
                VStack(spacing: 1) {
                    sectionHeader("4 FINGERS")
                    CompactGestureRow(slot: .fourFingerDoubleTap, appState: appState)
                    CompactGestureRow(slot: .fourFingerClick, appState: appState)
                    CompactGestureRow(slot: .fourFingerDoubleClick, appState: appState)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private func headerText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.bottom, 16)
    }
    
    private func sectionHeader(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.bottom, 4)
    }
}

struct CompactGestureRow: View {
    let slot: GestureSlot
    let appState: AppState
    
    var body: some View {
        HStack(spacing: 12) {
            Text(slot.displayName.uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 90, alignment: .leading)
            
            GestureRowView(
                slot: slot,
                isConflicting: appState.conflictingSlots.contains(slot),
                onShortcutChange: appState.handleShortcutConfigurationChange
            )
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(appState.conflictingSlots.contains(slot) ? Color.orange.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
