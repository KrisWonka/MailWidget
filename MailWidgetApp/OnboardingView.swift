import SwiftUI
import AppKit

/// 首次启动配置向导。原来只有三步权限引导；去个人化后追加两步——日报邮箱、
/// AI 引擎——因为这两项原来都是写死在代码/配置文件里的个人信息，朋友拿到源码后
/// 必须能在 App 里填完，不用改代码。
///
/// 内容包在 ScrollView 里而不是把窗口撑到能塞下五步：五步的总高度会超出常见屏幕
/// 可用高度，而且渲染验证 harness 用的是真实 NSWindow + NSHostingView +
/// cacheDisplay（不是 ImageRenderer——ImageRenderer 不渲染 ScrollView 内容），
/// 所以 ScrollView 在这个项目里是能验证到底的选择。
///
/// 也可以从 Settings 里的「重新打开配置向导」按钮再次打开（见 SettingsView），
/// 所以这个 View 不假设自己只会被展示一次。
struct OnboardingView: View {
    @State private var probeReport = ProviderProbe.run()

    // MARK: - 日报邮箱

    @State private var mailboxText: String = DailySummaryConstants.configuredMailbox ?? ""

    private var trimmedMailbox: String {
        mailboxText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 跟 SettingsView 里的校验同一条标准：非空 + 含 "@"。真正严格的邮箱格式
    /// 校验交给发布链路自己去校验实际收到的日报载荷（`DailySummary.mailbox`），
    /// 这里只挡明显打错的输入。
    private var mailboxIsValid: Bool {
        let value = trimmedMailbox
        guard !value.isEmpty, value.contains("@") else { return false }
        let parts = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }

    // MARK: - AI 引擎

    @State private var claudePath: String?
    @State private var codexPath: String?
    /// 真机部署实录：朋友的 codex 文件在、可执行位也在，但一跑 `codex exec` 就崩
    /// （"requires a newer version of Codex"），而向导只看"装没装"，于是这一步
    /// 显示✓、实际每次生成都失败。`AgentCLILocator.unusableReason(for:)` 会真的跑
    /// 一次 `--version`（带 10 分钟缓存），不能在 body 里直接调用，见 `refreshAll()`。
    @State private var claudeUnusableReason: String?
    @State private var codexUnusableReason: String?
    @State private var selectedEngineID: String?

    private var claudeInstalled: Bool { claudePath != nil }
    private var codexInstalled: Bool { codexPath != nil }
    private var claudeUsable: Bool { claudeInstalled && claudeUnusableReason == nil }
    private var codexUsable: Bool { codexInstalled && codexUnusableReason == nil }
    private var noEngineInstalled: Bool { !claudeInstalled && !codexInstalled }
    /// 装了但一个能用的都没有——这一步不该显示"完成"，即使 `noEngineInstalled`
    /// 为 false（文件确实都在）。
    private var hasUsableEngine: Bool { claudeUsable || codexUsable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to MailWidget")
                    .font(.title2.bold())
                Text("几步配置就能在桌面上看到未读邮件和 Gmail 日报。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    OnboardingStepRow(
                        number: 1,
                        title: "Grant Full Disk Access",
                        detail: "MailWidget reads Mail's local database to show unread counts instantly.",
                        isDone: probeReport.envelopeIndexAvailable
                    ) {
                        Button("Open System Settings…") {
                            openPrivacySettings()
                        }
                    }

                    OnboardingStepRow(
                        number: 2,
                        title: "Start automatic refresh",
                        detail: "MailWidget checks for new mail in the background on the interval you choose in Settings.",
                        isDone: true
                    ) {
                        Button("Refresh Now") {
                            Task { _ = await RefreshScheduler.shared.refreshNow() }
                        }
                    }

                    OnboardingStepRow(
                        number: 3,
                        title: "Add the widget to your desktop",
                        detail: "Right-click your desktop, choose Edit Widgets…, search \u{201C}MailWidget\u{201D}, then drag it onto your desktop.",
                        isDone: false
                    ) {
                        EmptyView()
                    }

                    OnboardingStepRow(
                        number: 4,
                        title: "你的 Gmail 地址",
                        detail: "日报会总结这个邮箱，AI 侧读邮件也用它。留空则首次收到日报时自动认领该邮箱。",
                        isDone: mailboxIsValid
                    ) {
                        MailboxStepContent(
                            mailboxText: mailboxText,
                            isValid: mailboxIsValid,
                            onChangeText: { newValue in
                                mailboxText = newValue
                                commitMailbox()
                            }
                        )
                    }

                    OnboardingStepRow(
                        number: 5,
                        title: "AI 引擎",
                        detail: "日报和邮件总结都靠本机的 claude 或 codex 命令行生成，选一个当前已安装的作为默认引擎。",
                        isDone: hasUsableEngine
                    ) {
                        AgentEngineStepContent(
                            claudePath: claudePath,
                            codexPath: codexPath,
                            claudeUnusableReason: claudeUnusableReason,
                            codexUnusableReason: codexUnusableReason,
                            selectedEngineID: selectedEngineID,
                            onSelect: selectEngine,
                            onChoosePath: choosePath
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }

            Divider()

            HStack {
                Spacer()
                Button("完成") {
                    closeWindow()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 560)
        .onAppear {
            refreshAll()
        }
    }

    private func refreshAll(bypassUnusableReasonCache: Bool = false) {
        probeReport = ProviderProbe.run()
        claudePath = AgentCLILocator.path(for: .claude)
        codexPath = AgentCLILocator.path(for: .codex)
        if selectedEngineID == nil {
            selectedEngineID = Self.initialSelectedEngineID(
                claudeInstalled: claudePath != nil,
                codexInstalled: codexPath != nil
            )
        }
        refreshUnusableReasons(bypassCache: bypassUnusableReasonCache)
    }

    /// `AgentCLILocator.unusableReason(for:)` 真的会跑一次 `<cli> --version` 子进程
    /// （内部带 10 分钟缓存），不能在视图 body 里直接调用——丢到后台队列跑。
    /// `bypassCache: true` 用于"用户刚手动指定了路径"这个场景：一个新路径值得
    /// 立刻验证一次，不该被上一个路径的缓存结果挡住长达 10 分钟。
    private func refreshUnusableReasons(bypassCache: Bool) {
        let claudePathSnapshot = claudePath
        let codexPathSnapshot = codexPath
        Task {
            let result: (claude: String?, codex: String?) = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let claude: String?
                    let codex: String?
                    if bypassCache {
                        claude = AgentCLILocator.probeUnusableReason(executablePath: claudePathSnapshot, cliDisplayName: AgentCLI.claude.rawValue)
                        codex = AgentCLILocator.probeUnusableReason(executablePath: codexPathSnapshot, cliDisplayName: AgentCLI.codex.rawValue)
                    } else {
                        claude = AgentCLILocator.unusableReason(for: .claude)
                        codex = AgentCLILocator.unusableReason(for: .codex)
                    }
                    continuation.resume(returning: (claude, codex))
                }
            }
            claudeUnusableReason = result.claude
            codexUnusableReason = result.codex
        }
    }

    /// 优先沿用已有配置（日报源 / 总结引擎，谁先命中一个已安装的 CLI 就用谁），
    /// 都没命中时按 claude 优先、codex 次之回落到"任意已安装的一个"，两个都没装
    /// 就是 nil——UI 上会显示"需要先安装"的提示，不强行选一个装不了的。
    private static func initialSelectedEngineID(claudeInstalled: Bool, codexInstalled: Bool) -> String? {
        for candidate in [DailySourceSettings.selectedSource, MailSummarizer.engine] {
            if candidate == AgentCLI.claude.rawValue, claudeInstalled { return candidate }
            if candidate == AgentCLI.codex.rawValue, codexInstalled { return candidate }
        }
        if claudeInstalled { return AgentCLI.claude.rawValue }
        if codexInstalled { return AgentCLI.codex.rawValue }
        return nil
    }

    private func commitMailbox() {
        DailySummaryConstants.configuredMailbox = trimmedMailbox.isEmpty ? nil : (mailboxIsValid ? trimmedMailbox : nil)
    }

    private func selectEngine(_ id: String) {
        selectedEngineID = id
        DailySourceSettings.selectedSource = id
        MailSummarizer.engine = id
        DailySourceSettings.registerSource(id)
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
        refreshAll(bypassUnusableReasonCache: true)
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}

private struct OnboardingStepRow<Action: View>: View {
    let number: Int
    let title: String
    let detail: String
    let isDone: Bool
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isDone ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: 26, height: 26)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                action()
            }
        }
    }
}

/// 邮箱步骤的纯渲染内容：不持有 @State，文本和校验结果都是入参、改动通过回调
/// 交回 `OnboardingView`——跟 `AgentEngineStepContent` 同一个拆分理由，渲染验证
/// harness 能直接灌固定字符串（合法/非法/空）截图，不用真的驱动一次 TextField
/// 输入才能出一张有内容的截图。
struct MailboxStepContent: View {
    let mailboxText: String
    let isValid: Bool
    let onChangeText: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("you@example.com", text: Binding(get: { mailboxText }, set: onChangeText))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            if !mailboxText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isValid {
                Text("这不像一个邮箱地址")
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }
}

/// AI 引擎选择步骤的纯渲染内容：不读 AgentCLILocator/DailySourceSettings，所有展示
/// 数据都是入参、写回动作都是回调——跟本文件其它 Section 拆分的理由一样，渲染
/// 验证 harness 能直接灌固定的 fixture（比如"claude 已装、codex 未装"）截图，
/// 不需要真机装好这两个 CLI 才能出一张有内容的截图。
struct AgentEngineStepContent: View {
    let claudePath: String?
    let codexPath: String?
    /// 非 nil = 已安装但跑不起来；nil = 要么没装、要么装了且能跑。见
    /// `AgentCLILocator.unusableReason(for:)` 顶部的真机部署实录注释。
    let claudeUnusableReason: String?
    let codexUnusableReason: String?
    let selectedEngineID: String?
    let onSelect: (String) -> Void
    let onChoosePath: (AgentCLI) -> Void

    private var claudeInstalled: Bool { claudePath != nil }
    private var codexInstalled: Bool { codexPath != nil }
    private var claudeUsable: Bool { claudeInstalled && claudeUnusableReason == nil }
    private var codexUsable: Bool { codexInstalled && codexUnusableReason == nil }
    private var noEngineInstalled: Bool { !claudeInstalled && !codexInstalled }
    /// 都装了，但一个能用的都没有——跟"完全没装"是两种不同的提示语，不该混在一起。
    private var noUsableEngine: Bool { !noEngineInstalled && !claudeUsable && !codexUsable }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentEngineRow(
                cli: .claude,
                displayName: "Claude",
                path: claudePath,
                unusableReason: claudeUnusableReason,
                isSelected: selectedEngineID == AgentCLI.claude.rawValue,
                onSelect: { onSelect(AgentCLI.claude.rawValue) },
                onChoosePath: { onChoosePath(.claude) }
            )
            AgentEngineRow(
                cli: .codex,
                displayName: "Codex",
                path: codexPath,
                unusableReason: codexUnusableReason,
                isSelected: selectedEngineID == AgentCLI.codex.rawValue,
                onSelect: { onSelect(AgentCLI.codex.rawValue) },
                onChoosePath: { onChoosePath(.codex) }
            )

            if noEngineInstalled {
                Text("需要先安装 claude 或 codex 命令行才能生成日报/总结。安装其中一个：`npm install -g @anthropic-ai/claude-code`（Claude）或参考 Codex CLI 的安装说明，装好后回到这一步重新选择。")
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if noUsableEngine {
                Text("已安装的命令行都无法正常运行，日报/总结会持续失败——按下面每行的提示升级后，重新指定一次路径即可重新验证。")
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AgentEngineRow: View {
    let cli: AgentCLI
    let displayName: String
    let path: String?
    let unusableReason: String?
    let isSelected: Bool
    let onSelect: () -> Void
    let onChoosePath: () -> Void

    private var isInstalled: Bool { path != nil }
    private var isUsable: Bool { isInstalled && unusableReason == nil }

    private var upgradeHint: String {
        switch cli {
        case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: return "npm install -g @openai/codex@latest"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: onSelect) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isInstalled ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!isInstalled)

                statusIcon

                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName).font(.subheadline.bold())
                    Text(isInstalled ? "已检测到 \(path!)" : "未安装")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                Button("手动指定路径…", action: onChoosePath)
                    .font(.caption)
            }

            // 已安装但跑不起来：三态里唯一新增的一档，路径照旧显示在上面那行，
            // 这里只补一句原因 + 一条能直接抄的升级命令。
            if let unusableReason, isInstalled {
                VStack(alignment: .leading, spacing: 2) {
                    Text("⚠ 已安装但无法运行：\(unusableReason)")
                        .font(.caption2)
                        .foregroundStyle(Color.red)
                    Text("可能需要升级：\(upgradeHint)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.leading, 34)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if !isInstalled {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.red)
        } else if !isUsable {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        }
    }
}
