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

    /// 去个人化：日报邮箱不再写死在代码里，朋友装好后要能在这里填。跟
    /// `OnboardingView` 用同一套校验标准（非空 + 含 "@"），失焦/每次改动即写回
    /// `DailySummaryConstants.configuredMailbox`，不需要单独的「保存」按钮。
    @State private var mailboxText = DailySummaryConstants.configuredMailbox ?? ""

    /// 契约：`AgentCLILocator` 探测本机装了哪些 CLI。两行各自独立刷新/指定路径，
    /// 跟 `dailySource`/`summaryEngine` 是两件事——这里只负责"这台机器上这两个
    /// 命令有没有、在哪"，选哪个当日报源/总结引擎仍由下面各自的 Picker 决定。
    @State private var claudePath: String? = AgentCLILocator.path(for: .claude)
    @State private var codexPath: String? = AgentCLILocator.path(for: .codex)

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

            agentCLISection

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
        .frame(width: 460, height: 680)
        .onAppear {
            lastRefreshDate = SnapshotStore.load()?.generatedAt
            probeReport = ProviderProbe.run()
            reloadDailyState()
            reloadMailSummaryState()
            reloadAgentCLIState()
        }
    }

    // MARK: - Gmail 日报

    private var trimmedMailboxText: String {
        mailboxText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 跟 `OnboardingView.mailboxIsValid` 同一条标准，两处各自维护而不是共享一个
    /// 工具函数——都只有两行逻辑，抽出去反而多一层间接。
    private var mailboxIsValid: Bool {
        let value = trimmedMailboxText
        guard !value.isEmpty, value.contains("@") else { return false }
        let parts = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }

    private var gmailDailySection: some View {
        Section("Gmail 日报") {
            MailboxFieldContent(
                mailboxText: mailboxText,
                isValid: mailboxIsValid,
                onChangeText: { newValue in
                    mailboxText = newValue
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    DailySummaryConstants.configuredMailbox = trimmed.isEmpty ? nil : (mailboxIsValid ? trimmed : nil)
                }
            )

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

    // MARK: - AI 命令行

    /// 渲染逻辑抽成无状态的 `AgentCLISectionContent`（跟 `MailSummarySectionContent`
    /// 同一个拆分理由）：这里只负责把探测结果和写回动作接进去，渲染验证 harness
    /// 能直接灌固定的 fixture（比如"claude 已装、codex 未装"）截图，不用真机装好
    /// 这两个 CLI 才能出一张有内容的截图。
    private var agentCLISection: some View {
        AgentCLISectionContent(
            claudePath: claudePath,
            codexPath: codexPath,
            onChoosePath: choosePath,
            onRedetect: redetect,
            onReopenOnboarding: reopenOnboarding
        )
    }

    private func reloadAgentCLIState() {
        claudePath = AgentCLILocator.path(for: .claude)
        codexPath = AgentCLILocator.path(for: .codex)
    }

    private func choosePath(for cli: AgentCLI) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择 \(cli.rawValue) 命令行可执行文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AgentCLILocator.setOverride(url.path, for: cli)
        reloadAgentCLIState()
    }

    /// 清掉手动指定的 override 后重新走一遍 `path(for:)`——用于用户挪动/重装了
    /// CLI，想让 App 忘记旧的手动路径、重新自动探测的场景。
    private func redetect(for cli: AgentCLI) {
        AgentCLILocator.setOverride(nil, for: cli)
        reloadAgentCLIState()
    }

    private func reopenOnboarding() {
        (NSApp.delegate as? AppDelegate)?.showOnboardingWindow()
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
    /// 自动化状态（「配置…」按钮就地弹出 popover——原来挂在总结窗口 header 的 ⏰
    /// 图标上，两个 host 窗口 header 统一样式后整个搬来这里，见
    /// `MailSummaryAutomationConfigButton`）+ 上次总结时间 + 打开窗口/复制命令两个
    /// 出口 + 一段说明 footnote。
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
            onAutomationChange: reloadMailSummaryState,
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
    /// 回落到 `MailScope.all`——`MailSummaryAutomationConfigButton` 内部的
    /// `reloadFromSettings()` 同样落到 `MailScope.all`，这里没有"当前总结窗口"
    /// 这个上下文可用（Settings 是独立窗口），"all" 是唯一合理的默认。
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
    /// 只给「打开总结窗口」用——「配置…」不再打开这个窗口，见
    /// `MailSummaryAutomationConfigButton`（自动化面板已经搬到这个文件里，就地弹
    /// popover，不用再跳窗口）。
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
///
/// 「配置…」这里例外——它是 `MailSummaryAutomationConfigButton`（下方定义，有自己的
/// @State），不是靠回调转发的纯展示元素：真的点击它会打开一个 popover 并可能触发
/// 真实的 install/uninstall I/O，但仅仅是把这个视图渲染到屏幕上（构造它、显示它）
/// 不会触发任何 I/O——@State 初值都是字面量，读盘只发生在按钮被点击、`showPanel`
/// 变 true 之后。所以渲染验证 harness 直接把整个 `MailSummarySectionContent` 渲染
/// 出来仍然是安全的、确定性的。
struct MailSummarySectionContent: View {
    let engine: Binding<String>
    let automationStatusText: String
    let lastSummaryText: String
    /// 自动化面板成功装载/停用后调用，让「自动化」行的状态短句立刻反映最新配置——
    /// 不然用户在 popover 里勾选了 Toggle，旁边那行字要等下次窗口重新打开
    /// （`.onAppear`）才会更新，体验上像是"改了但没生效"。
    let onAutomationChange: () -> Void
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
                    MailSummaryAutomationConfigButton(onChange: onAutomationChange)
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

/// 「配置…」打开一个设置面板（popover）——契约 12 自动化的唯一配置入口。原来挂在
/// 邮件总结窗口 header 的 ⏰ 图标上；用户对比两个 host 窗口的截图反馈 header 该长
/// 一个样后（统一成"左 ⚙️ 右 ↻，都是纯图标"），整个自动化面板搬进了 SettingsView，
/// 窗口 header 不再有第三个功能入口。面板内的 Toggle/时间/范围本身就是明确操作，
/// 不需要再弹一层确认框。
///
/// 状态短句只有两种颜色：secondary 灰色（当前的真实状态：已启用到几点几分，或未
/// 启用）、红色（上一次操作失败，只给"启用/停用/保存失败"这种短句，技术性细节
/// 留给 `~/Library/Logs/mailwidget-mail-summary.log`，不堆在 UI 里）。
///
/// 这个组件本身持有 @State（真实的 Toggle 开关要触发真实的 install/uninstall
/// I/O），但面板本身的渲染逻辑是无状态的 `MailSummaryAutomationPanelContent`（定义
/// 在 `MailSummaryView.swift`——契约 12 总结窗口那批类型还在那边，只是这个"打开
/// 它"的按钮搬了家）：渲染验证 harness 能直接用 `.constant(...)` 绑定灌固定状态，
/// 不用真的写 App Group defaults 或真的调 launchctl。
private struct MailSummaryAutomationConfigButton: View {
    var onChange: () -> Void = {}

    private enum Action { case enable, disable, save }

    @State private var showPanel = false
    @State private var isEnabled = false
    @State private var hour = MailSummaryAutomationInstaller.defaultHour
    @State private var minute = MailSummaryAutomationInstaller.defaultMinute
    @State private var scopeID = MailScope.all
    @State private var isBusy = false
    @State private var failedAction: Action?

    var body: some View {
        Button("配置…") {
            reloadFromSettings()
            showPanel = true
        }
        .popover(isPresented: $showPanel, arrowEdge: .top) {
            MailSummaryAutomationPanelContent(
                statusText: statusText,
                statusIsError: failedAction != nil,
                engineDisplayName: MailSummaryEngineDisplay.name(for: MailSummarizer.engine),
                isEnabled: $isEnabled,
                time: timeBinding,
                scopeID: $scopeID,
                accountOptions: accountOptions,
                isBusy: isBusy,
                onToggle: { newValue in
                    if newValue {
                        performInstall(action: .enable)
                    } else {
                        performUninstall()
                    }
                },
                onSave: { performInstall(action: .save) }
            )
        }
    }

    private var accountOptions: [(id: String, name: String)] {
        (SnapshotStore.load()?.accounts ?? []).map { (id: $0.id, name: $0.name) }
    }

    /// `DatePicker` 要的是 `Date`；面板内部只关心时:分，年月日一律用当前日期占位，
    /// 写回时只取 `.hour`/`.minute` 两个分量。
    private var timeBinding: Binding<Date> {
        Binding(
            get: { Self.date(hour: hour, minute: minute) },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                hour = components.hour ?? hour
                minute = components.minute ?? minute
            }
        )
    }

    private static func date(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    private var statusText: String {
        switch failedAction {
        case .enable: return "启用失败"
        case .disable: return "停用失败"
        case .save: return "保存失败"
        case nil: return isEnabled ? String(format: "每天 %02d:%02d · 已启用", hour, minute) : "未启用"
        }
    }

    /// 面板每次打开都重新校准——不只是读上次的草稿，是因为 plist 有可能在窗口关着
    /// 的这段时间被外部改动过（用户手动删了文件、或者另一次 Settings 窗口的面板
    /// 已经保存过新配置）。`reconcileEnabledWithDisk()` 保证 `isEnabled` 不是过期的。
    /// 没配置过（`scopeID == nil`）落到 `MailScope.all`——这里没有"当前总结窗口"
    /// 这个上下文可用，"all" 是唯一合理的默认。
    private func reloadFromSettings() {
        isEnabled = MailSummaryAutomationSettings.reconcileEnabledWithDisk()
        hour = MailSummaryAutomationSettings.hour
        minute = MailSummaryAutomationSettings.minute
        scopeID = MailSummaryAutomationSettings.scopeID ?? MailScope.all
        failedAction = nil
    }

    /// Toggle 打开 与「保存」共用同一条装载路径——两者的语义都是"用当前面板草稿去
    /// (重新) 装载"，区别只是失败时该说"启用失败"还是"保存失败"。成功/失败都调
    /// `onChange()`，让「自动化」行的状态短句跟着刷新。
    private func performInstall(action: Action) {
        failedAction = nil
        isBusy = true
        do {
            try MailSummaryAutomationInstaller.install(scopeID: scopeID, hour: hour, minute: minute)
            isEnabled = true
        } catch {
            failedAction = action
            // 装载失败不代表"之前那份"也失效了——用磁盘上 plist 是否存在重新校准，
            // 而不是简单地把 isEnabled 悲观地拍成 false。
            isEnabled = MailSummaryAutomationSettings.reconcileEnabledWithDisk()
        }
        isBusy = false
        onChange()
    }

    private func performUninstall() {
        failedAction = nil
        isBusy = true
        MailSummaryAutomationInstaller.uninstall()
        isEnabled = false
        isBusy = false
        onChange()
    }
}

/// 「日报邮箱」输入框的纯渲染内容：不读/写 `DailySummaryConstants.configuredMailbox`，
/// 文本和校验结果都是入参，改动通过回调交回 `SettingsView`——跟 `MailSummarySectionContent`
/// 同一个拆分理由，渲染验证 harness 能直接灌固定字符串（合法/非法/空）截图。
/// `OnboardingView.MailboxStepContent` 是同一形状但独立的一份——两处提示文案不同
/// （这里多一句"未配置，日报无法发布"），各自维护比抽共享组件更省事。
struct MailboxFieldContent: View {
    let mailboxText: String
    let isValid: Bool
    let onChangeText: (String) -> Void

    private var trimmed: String {
        mailboxText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 不能给 `TextField` 传非空标题——哪怕嵌在 `LabeledContent` 里，macOS
            // 的 Form 仍会把标题参数当成一段持久文字标签渲染到框外（实测："you@
            // example.com" 顶着框跑到右边，还被系统文本数据检测识别成邮箱链接、
            // 变成蓝色可点文字，framework 层面的怪癖，不是布局宽度问题）。改成
            // 空标题 + `.overlay` 手绘 placeholder，彻底绕开这条路径；标题信息
            // 由 `LabeledContent` 的 "日报邮箱" 承担，这里补一个 `accessibilityLabel`
            // 保住无障碍语义。
            LabeledContent("日报邮箱") {
                TextField("", text: Binding(get: { mailboxText }, set: onChangeText))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("日报邮箱")
                    .overlay(alignment: .leading) {
                        if mailboxText.isEmpty {
                            Text("you@example.com")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 6)
                                .allowsHitTesting(false)
                        }
                    }
            }
            if trimmed.isEmpty {
                Text("未配置，日报无法发布")
                    .font(.caption)
                    .foregroundStyle(Color.red)
            } else if !isValid {
                Text("这不像一个邮箱地址")
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }
}

/// 「AI 命令行」Section 的纯渲染内容：不读 `AgentCLILocator`，探测结果全是入参、
/// 写回动作全是回调——跟 `MailSummarySectionContent` 同一个拆分理由，渲染验证
/// harness 能直接灌固定字符串就重现"claude 已装 / codex 未装"这类截图。
struct AgentCLISectionContent: View {
    let claudePath: String?
    let codexPath: String?
    let onChoosePath: (AgentCLI) -> Void
    let onRedetect: (AgentCLI) -> Void
    let onReopenOnboarding: () -> Void

    var body: some View {
        Section("AI 命令行") {
            AgentCLIStatusRow(
                cli: .claude,
                displayName: "Claude",
                path: claudePath,
                onChoosePath: { onChoosePath(.claude) },
                onRedetect: { onRedetect(.claude) }
            )
            AgentCLIStatusRow(
                cli: .codex,
                displayName: "Codex",
                path: codexPath,
                onChoosePath: { onChoosePath(.codex) },
                onRedetect: { onRedetect(.codex) }
            )

            Button("重新打开配置向导", action: onReopenOnboarding)

            Text("日报和邮件总结引擎的选择在上面两个 Section 里；这里只负责这台机器上有没有装、装在哪。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AgentCLIStatusRow: View {
    let cli: AgentCLI
    let displayName: String
    let path: String?
    let onChoosePath: () -> Void
    let onRedetect: () -> Void

    var body: some View {
        LabeledContent(displayName) {
            HStack(spacing: 8) {
                Text(path ?? "未安装")
                    .font(.caption)
                    .foregroundStyle(path == nil ? Color.red : .secondary)
                    .textSelection(.enabled)
                Button("指定路径…", action: onChoosePath)
                Button("重新探测", action: onRedetect)
            }
        }
    }
}
