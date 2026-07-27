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

    @State private var dailySource = DailySourceSettings.selectedSource
    @State private var knownSources = DailySourceSettings.knownSources
    @State private var dailyStatus = ""
    @State private var dailyStatusIsError = false

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

            gmailDailySection

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
        .frame(width: 460, height: 620)
        .onAppear {
            lastRefreshDate = SnapshotStore.load()?.generatedAt
            probeReport = ProviderProbe.run()
            reloadDailyState()
        }
    }

    // MARK: - Gmail 日报

    private var gmailDailySection: some View {
        Section("Gmail 日报") {
            Picker("日报源", selection: $dailySource) {
                ForEach(knownSources, id: \.self) { source in
                    Text(source).tag(source)
                }
            }
            .onChange(of: dailySource) { _, newValue in
                DailySourceSettings.selectedSource = newValue
                dailyStatus = "已切换到 \(newValue)。其它来源的载荷会被忽略，当前日报不受影响。"
            }

            Text(lastIngestDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(codexButtonTitle) { perform { try DailySourceInstaller.updateExistingCodexAutomation() } }
                .disabled(DailySourceInstaller.existingCodexAutomationURL == nil)

            Button("一键添加到 Claude…") { perform { try DailySourceInstaller.installClaudeJob() } }
                .disabled(DailySourceInstaller.discoveredClaudePath == nil)

            HStack {
                Button("复制提示词") {
                    perform { try DailySourceInstaller.copyPromptToPasteboard(sourceID: dailySource) }
                }
                Button("导出模板…") { exportTemplate() }
            }

            Text("能读 Gmail、能跑 shell 命令的 agent 都能接；定时和增量游标由本 App 补齐。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !dailyStatus.isEmpty {
                Text(dailyStatus)
                    .font(.caption)
                    .foregroundStyle(dailyStatusIsError ? Color.red : Color.green)
                    .textSelection(.enabled)
            }
        }
    }

    private var codexButtonTitle: String {
        DailySourceInstaller.existingCodexAutomationURL == nil
            ? "未检测到 Codex 日报任务"
            : "更新现有 Codex 任务的 ingest 路径"
    }

    private var lastIngestDescription: String {
        guard let at = DailySourceSettings.lastIngestAt else {
            return "尚未收到日报"
        }
        let who = DailySourceSettings.lastSource.flatMap { $0.isEmpty ? nil : $0 } ?? "未标注来源"
        return "上次日报：\(who)、\(at.formatted(date: .abbreviated, time: .shortened))"
    }

    private func reloadDailyState() {
        knownSources = DailySourceSettings.knownSources
        dailySource = DailySourceSettings.selectedSource
    }

    /// 所有出口共用同一条反馈路径：成功显示做了什么、写了哪些文件；失败原样显示错误，
    /// 不吞掉。这些操作会改别人的配置文件，静默失败是最糟的结果。
    private func perform(_ action: () throws -> DailySourceInstaller.Outcome) {
        do {
            let outcome = try action()
            dailyStatusIsError = false
            dailyStatus = outcome.writtenPaths.isEmpty
                ? outcome.summary
                : outcome.summary + "\n" + outcome.writtenPaths.joined(separator: "\n")
            reloadDailyState()
        } catch {
            dailyStatusIsError = true
            dailyStatus = error.localizedDescription
        }
    }

    private func exportTemplate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "导出到这里"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        perform { try DailySourceInstaller.exportTemplate(sourceID: dailySource, to: directory) }
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
