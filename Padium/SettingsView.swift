import SwiftUI

struct SettingsContentView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PADIUM")
                        .font(.system(size: 24, weight: .heavy, design: .monospaced))
                        .tracking(4)
                        .padding(.top, 8)
                    Text("TRACKPAD GESTURES TO SHORTCUTS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                
                Spacer()
                
                if appState.runtimeStatus == .active && appState.conflictingSlots.isEmpty {
                    statusBadge(title: "ACTIVE", color: .green)
                } else if appState.runtimeStatus == .permissionsRequired {
                    statusBadge(title: "PERMISSIONS", color: .red)
                } else if appState.runtimeStatus == .paused {
                    statusBadge(title: "PAUSED", color: .secondary)
                } else if appState.runtimeStatus == .degraded {
                    statusBadge(title: "DEGRADED", color: .orange)
                } else if appState.runtimeStatus == .checking {
                    statusBadge(title: "CHECKING", color: .secondary)
                } else {
                    statusBadge(title: "CONFLICTS", color: .orange)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            if appState.runtimeStatus == .permissionsRequired {
                permissionRequiredView
            } else {
                VStack(spacing: 0) {
                    if appState.runtimeStatus == .degraded {
                        runtimeAttentionView
                        Divider()
                    }
                    if appState.isPaused {
                        pausedBanner
                        Divider()
                    }
                    if appState.systemGestureNotice != nil {
                        systemGestureConflictBanner
                        Divider()
                    }
                    gestureConfigurationView
                }
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

                Text(sensitivityReadout(for: appState.gestureSensitivity))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .leading)

                Spacer()

                Button(appState.isGestureFeedbackEnabled ? "FEEDBACK ON" : "FEEDBACK OFF") {
                    appState.toggleGestureFeedback()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(appState.isGestureFeedbackEnabled ? Color.accentColor : Color.secondary)
                .padding(.trailing, 12)
                .help("Briefly show which gesture and shortcut fired.")

                Button(appState.isPaused ? "RESUME" : "PAUSE") {
                    appState.togglePaused()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(appState.isPaused ? Color.accentColor : Color.secondary)
                .padding(.trailing, 12)

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
        .frame(width: 740)
        .onAppear {
            appState.refreshPermissions()
        }
    }
    
    private func sensitivityReadout(for value: Double) -> String {
        let range = GestureSensitivitySetting.maximumValue - GestureSensitivitySetting.minimumValue
        guard range > 0 else { return "0%" }
        let clamped = min(max(value, GestureSensitivitySetting.minimumValue), GestureSensitivitySetting.maximumValue)
        let normalized = (clamped - GestureSensitivitySetting.minimumValue) / range
        return "\(Int(round(normalized * 100)))%"
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
            
            Text("PERMISSIONS REQUIRED")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(appState.missingPermissionMessages.enumerated()), id: \.offset) { _, message in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                        Text(message)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 40)

            HStack(spacing: 12) {
                Button("Grant Missing Access") {
                    appState.requestMissingPermissions()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button("Refresh") {
                    appState.refreshPermissions()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pausedBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("PADIUM IS PAUSED")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                Text("Gestures will not fire until you resume.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Resume") {
                appState.setPaused(false)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.secondary.opacity(0.08))
    }

    private var systemGestureConflictBanner: some View {
        let conflicts = appState.systemGestureSettings()
        let conflictingPadiumSlots = appState.conflictingSlots

        return VStack(alignment: .leading, spacing: 10) {
            Text("MACOS GESTURES STILL ACTIVE")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)

            Text("These macOS trackpad gestures will fire alongside Padium until they're turned off in System Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(conflicts) { conflict in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conflict.title)
                                .font(.system(size: 12, weight: .medium))
                            let overlap = conflict.conflictingSlots.filter(conflictingPadiumSlots.contains)
                            if !overlap.isEmpty {
                                Text("Overlaps Padium: \(overlap.map(\.displayName).joined(separator: ", "))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Button("Open Trackpad Settings") {
                appState.openTrackpadSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.orange.opacity(0.08))
    }

    private var runtimeAttentionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RUNTIME ATTENTION")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(appState.missingPermissionMessages.enumerated()), id: \.offset) { _, message in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                        Text(message)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }

                ForEach(Array(appState.runtimeFailureMessages.enumerated()), id: \.offset) { _, message in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                        Text(message)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                if !appState.missingPermissionMessages.isEmpty {
                    Button("Grant Missing Access") {
                        appState.requestMissingPermissions()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }

                Button("Refresh") {
                    appState.refreshPermissions()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.orange.opacity(0.08))
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
