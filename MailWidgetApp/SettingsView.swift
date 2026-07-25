import SwiftUI
import AppKit
import ServiceManagement

/// Contract 5: shared UserDefaults suite that backend's RefreshScheduler also reads.
/// Uses DataKit's own `SharedConstants` so the App Group ID / key can't drift between us.
private let sharedDefaults = UserDefaults(suiteName: SharedConstants.appGroupIdentifier)

struct SettingsView: View {
    @AppStorage(SharedConstants.refreshIntervalMinutesKey, store: sharedDefaults)
    private var refreshIntervalMinutes: Double = SharedConstants.defaultRefreshIntervalMinutes

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var probeReport = ProviderProbe.run()
    @State private var lastRefreshDate: Date?

    var body: some View {
        Form {
            Section("Refresh") {
                Stepper(value: $refreshIntervalMinutes, in: 1...60, step: 1) {
                    Text("Refresh every \(Int(refreshIntervalMinutes)) min")
                }
                if let lastRefreshDate {
                    Text("Last refreshed \(lastRefreshDate.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never refreshed yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }
            }

            Section("Permissions") {
                LabeledContent("Full Disk Access") {
                    permissionBadge(probeReport.envelopeIndexAvailable)
                }
                Text(probeReport.envelopeIndexDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Active data source", value: probeReport.activeProvider)

                HStack {
                    Button("Open System Settings…") {
                        openPrivacySettings()
                    }
                    Button("Re-check") {
                        probeReport = ProviderProbe.run()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 440, height: 420)
        .onAppear {
            lastRefreshDate = SnapshotStore.load()?.generatedAt
            probeReport = ProviderProbe.run()
        }
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    @ViewBuilder
    private func permissionBadge(_ granted: Bool) -> some View {
        Label(granted ? "Granted" : "Not Granted", systemImage: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(granted ? Color.green : Color.red)
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
