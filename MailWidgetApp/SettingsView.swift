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

    @State private var summaryEngine = MailSummarizer.engine
    @State private var summaryAutomationEnabled = false
    @State private var summaryAutomationHour = MailSummaryAutomationInstaller.defaultHour
    @State private var summaryAutomationMinute = MailSummaryAutomationInstaller.defaultMinute
    @State private var summaryAutomationScopeID = MailScope.all

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

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

            mailSummarySection

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
            reloadMailSummaryState()
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

    // MARK: - 邮件总结（契约 12）

    /// 用户反馈："自动化在 Claude/Codex 应用里都看不到"——因为它走的是 launchd +
    /// CLI（`MailSummarizer.summarize` 起一个本机 claude/codex 子进程），跟"在
    /// Claude/Codex 应用里排一个任务"完全是两回事，UI 上必须写明白，不能让用户去
    /// 那两个应用里找。这个 Section 参照 `gmailDailySection` 的详细度：引擎选择 +
    /// 自动化状态（配置入口在总结窗口的 ⏰ popover，这里只展示状态、不重复做控件）+
    /// 上次总结时间 + 打开窗口/复制命令两个出口 + 一段说明 footnote。
    ///
    /// 渲染逻辑抽成无状态的 `MailSummarySectionContent`（跟 `MailSummaryContentView`/
    /// `MailSummaryAutomationPanelContent` 同一个拆分理由）：这里只负责把 `@State`
    /// 和写回动作接进去，渲染验证 harness 能直接灌固定字符串，不用真的读本机
    /// App Group defaults / launchd plist 才能出一张有内容的截图。
    private var mailSummarySection: some View {
        MailSummarySectionContent(
            engine: Binding(
                get: { summaryEngine },
                set: { newValue in
                    summaryEngine = newValue
                    // 引擎不涉及 launchd 重装（`MailSummarizer.summarize` 每次调用时才
                    // 读取这个值），改动即写回，不需要额外的「保存」步骤。
                    MailSummarizer.engine = newValue
                }
            ),
            automationStatusText: summaryAutomationStatusText,
            lastSummaryText: lastMailSummaryText,
            onConfigure: openMailSummaryWindow,
            onOpenWindow: openMailSummaryWindow,
            onCopyCommand: copySummarizeCommand
        )
    }

    /// 跟总结窗口 ⏰ popover 的 `statusText` 同一套语义（"每天 HH:mm · <范围名>" /
    /// "未启用"），只是这里额外带上范围名——popover 里范围就是当前编辑的那个,
    /// 不用重复说；Settings 里是"设置页概览"，值得把范围名一起摆出来。
    private var summaryAutomationStatusText: String {
        guard summaryAutomationEnabled else { return "未启用" }
        let scopeName = MailSummaryScopeResolver.resolve(scopeID: summaryAutomationScopeID, snapshot: SnapshotStore.load())
            ?? summaryAutomationScopeID
        return String(format: "每天 %02d:%02d · %@", summaryAutomationHour, summaryAutomationMinute, scopeName)
    }

    /// "当前配置 scope"：自动化配置过就用它的 scope，没配置过（`scopeID == nil`）
    /// 回落到 `MailScope.all`——跟 `MailSummaryAutomationButton.reloadFromSettings()`
    /// 里"没配置过用当前窗口 scope"不同，这里没有"当前窗口"这个上下文可用（Settings
    /// 是独立窗口），"all" 是唯一合理的默认。
    private var lastMailSummaryText: String {
        let scopeID = summaryAutomationScopeID
        let loaded: MailSummary?
        do {
            loaded = try MailSummaryStore().load(scopeID: scopeID)
        } catch {
            loaded = nil
        }
        guard let summary = loaded else { return "尚未生成" }
        let relative = Self.relativeFormatter.localizedString(for: summary.generatedAt, relativeTo: Date())
        let engineRaw = sharedDefaults?.string(forKey: MailSummarizer.lastEngineKey(forScopeID: scopeID)) ?? summaryEngine
        return "\(relative) · \(MailSummaryEngineDisplay.name(for: engineRaw))"
    }

    private func reloadMailSummaryState() {
        summaryEngine = MailSummarizer.engine
        summaryAutomationEnabled = MailSummaryAutomationSettings.reconcileEnabledWithDisk()
        summaryAutomationHour = MailSummaryAutomationSettings.hour
        summaryAutomationMinute = MailSummaryAutomationSettings.minute
        summaryAutomationScopeID = MailSummaryAutomationSettings.scopeID ?? MailScope.all
    }

    /// 总结窗口是同一进程里的单例窗口（`AppDelegate.showMailSummaryWindow`），
    /// 直接拿 delegate 调用，不用再绕一圈自发 `mailwidget://mailSummary` URL。
    /// 「配置…」和「打开总结窗口」共用这一个函数——两者语义相同，打开的是同一个
    /// 窗口，自动化面板（Toggle/时间/范围）本来就在那个窗口的 ⏰ 里，Settings 这边
    /// 不重复做一份。
    private func openMailSummaryWindow() {
        (NSApp.delegate as? AppDelegate)?.showMailSummaryWindow(scopeID: summaryAutomationScopeID)
    }

    /// 跟 `MailSummaryAutomationInstaller.install(scopeID:hour:minute:)` 内部拼
    /// launchd 脚本命令用的是同一个 `summarizeCommand(scopeID:)`，不是照抄一遍
    /// 字符串拼接——复制出来的命令永远和 launchd 实际在跑的那一行完全一致。
    private func copySummarizeCommand() {
        let command = MailSummaryAutomationInstaller.summarizeCommand(scopeID: summaryAutomationScopeID)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
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

/// 纯渲染的「邮件总结」Section 内容：不读 `MailSummaryAutomationSettings`、不读
/// `SnapshotStore`、不读 App Group defaults——所有展示文案都是入参，写回动作都是
/// 回调。渲染验证 harness 用固定字符串 + `.constant(...)`/普通 `Binding` 就能重现
/// 任意状态截图，不用真的触发 `SettingsView.reloadMailSummaryState()` 那条读盘路径。
struct MailSummarySectionContent: View {
    let engine: Binding<String>
    let automationStatusText: String
    let lastSummaryText: String
    let onConfigure: () -> Void
    let onOpenWindow: () -> Void
    let onCopyCommand: () -> Void

    var body: some View {
        Section("邮件总结") {
            Picker("总结引擎", selection: engine) {
                Text("Claude").tag(MailSummarizer.engineClaude)
                Text("Codex").tag(MailSummarizer.engineCodex)
            }

            LabeledContent("自动化") {
                HStack(spacing: 8) {
                    Text(automationStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("配置…", action: onConfigure)
                }
            }

            LabeledContent("上次总结", value: lastSummaryText)

            HStack {
                Button("打开总结窗口", action: onOpenWindow)
                Button("复制命令", action: onCopyCommand)
            }
            Text("可接入任何调度器或 agent")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("总结由本机 \(MailSummaryEngineDisplay.name(for: engine.wrappedValue)) 命令行离线触发，定时依赖 macOS launchd——不会出现在 Claude 或 Codex 应用的任务列表里。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
