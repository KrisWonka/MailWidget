// MailSummaryView.swift
// 契约 12 — 邮件总结详情窗口：widget 头部 text.magnifyingglass 按钮唤起。
//
// 与 DailyDetailView/DailyDetailModel 同一套"单例窗口 + 每次显示强制 reload"模式
// （见 App.swift 里 `showDailyDetailWindow` 的文档注释）——区别是这里的"reload"
// 不只是读一份已经落盘的缓存：没有缓存时会顺带触发一次真实生成，那是分钟级的
// 同步调用（`MailSummarizer.summarize`），绝不能占住调用它的线程，所以模型内部
// 把它扔到后台队列跑，跑完切回主线程更新 @Published 状态。
//
// 生成中的状态不是这个进程独占的——widget 按钮和 launchd 自动化都可能在另一个
// 进程里同时跑同一个 scope 的总结（防重入靠 App Group 里的
// `mailSummaryStartedAt.<scopeID>` 时间戳，15 分钟过期，DailyRegenerator 同款），
// 所以窗口开着的时候用 2 秒 Timer 轮询那个 flag 和 store，而不是只等自己发起的
// 那一次后台任务回调。
//
// `MailSummaryModel` ↔ `MailSummaryContentView` 的拆分是有意的：`MailSummaryView`
// 只做"从 model 读 @Published 状态、转发给一个纯渲染视图"这一件事。
// `MailSummaryContentView` 本身不碰任何 I/O（不读 SnapshotStore、不读 App Group
// defaults），渲染验证 harness（ImageRenderer）因此能直接拿手造的 fixture 构造它，
// 不需要经过 `MailSummaryModel`——经过 model 就意味着要么把 fixture 数据写进用户
// 真实的 App Group / 降级目录，要么真的触发 `MailSummarizer.summarize`（会起一个
// 真的 claude 子进程），两者都不是"渲染验证"应该做的事。

import AppKit
import SwiftUI

/// 契约 12 — 把 `mailwidget://mailSummary` 的 scope 字符串解析成窗口标题用的显示名，
/// 或者 nil（无法识别 / 账户在当前快照里已不存在）。
///
/// 与 `AppDelegate.markAllReadTarget(forScope:)` 同一套 fail-closed 判定：只认
/// "all" 与已存在账户的 "account:<id>"，别的一律拒绝。两处调用点共享这份判定——
/// URL 路由器拿它当"要不要打开窗口"的门槛，`MailSummaryModel` 拿它求窗口标题——
/// 不给出第二份逻辑，避免两处判据将来悄悄分叉（批 1 review 修的那个 fail-open
/// 教训，见 `App.swift`）。
enum MailSummaryScopeResolver {
    static func resolve(scopeID: String, snapshot: MailSnapshot?) -> String? {
        if scopeID == MailScope.all {
            return "全部收件箱"
        }
        guard scopeID.hasPrefix(MailScope.accountPrefix) else { return nil }
        let accountID = String(scopeID.dropFirst(MailScope.accountPrefix.count))
        return snapshot?.accounts.first(where: { $0.id == accountID })?.name
    }
}

/// 一「份」总结 + 它关联到的真实邮件（未读态、时间）。与 `DailyBrief`/
/// `DailyBriefItem`（`DataKit/DailyBrief.swift`）同一思路，独立一份是因为那份是
/// DataKit 侧类型、覆盖的是日报载荷（`DailySummaryItem`），这里覆盖的是契约 12
/// 的 `MailSummaryItem`，两份载荷结构不同，没有共同的父类型可提取。
struct MailSummaryDisplayItem: Identifiable {
    let item: MailSummaryItem
    let message: MessageSummary?

    var id: String { item.messageIdHeader }

    /// 关联不到快照（Mail 本地没同步到这封信）时不算未读——宁可少数，也不要让
    /// 蓝点变成猜的。与 `DailyBriefItem.isUnread` 同一判定。
    var isUnread: Bool { message?.isRead == false }
}

/// 一次总结的展示态：`MailSummaryStore` 落盘的 `MailSummary` 载荷 + 按
/// Message-ID 关联出的真实邮件信息。
struct MailSummaryBrief {
    let scopeName: String
    let generatedAt: Date
    let items: [MailSummaryDisplayItem]

    /// 同一封信可能同时出现在 inbox 和 vip/flagged 等伪邮箱里，先到先得即可，
    /// 内容一致——与 `DailyBrief.resolve` 里的关联表构造逐字同一处理。
    static func resolve(summary: MailSummary, snapshot: MailSnapshot?) -> MailSummaryBrief {
        var messagesByID: [String: MessageSummary] = [:]
        for account in snapshot?.accounts ?? [] {
            for mailbox in account.mailboxes {
                for message in mailbox.messages {
                    guard let header = message.messageIdHeader, messagesByID[header] == nil else { continue }
                    messagesByID[header] = message
                }
            }
        }

        let items = summary.items.map { item in
            MailSummaryDisplayItem(item: item, message: messagesByID[item.messageIdHeader])
        }
        return MailSummaryBrief(scopeName: summary.scopeName, generatedAt: summary.generatedAt, items: items)
    }
}

/// 总结窗口的可观察状态，由 `AppDelegate` 持有单例并注入——原因与
/// `DailyDetailModel` 完全一致：窗口是复用的（`isReleasedWhenClosed = false`），
/// `NSHostingView(rootView:)` 只在窗口第一次创建时实例化一次，视图自身的
/// `.onAppear` 不会在第二次 `makeKeyAndOrderFront` 时重新触发。
final class MailSummaryModel: ObservableObject {
    @Published private(set) var scopeID: String = MailScope.all
    /// 窗口标题用的显示名（中文，来自 `MailSummaryScopeResolver`）——与
    /// `brief?.scopeName`（落在总结载荷里、给 claude prompt 用的英文名，如
    /// "All Inboxes"）是两回事，故意不混用。
    @Published private(set) var windowTitle: String = ""
    @Published private(set) var brief: MailSummaryBrief?
    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?

    private let store = MailSummaryStore()
    private var pollTimer: Timer?

    deinit { pollTimer?.invalidate() }

    /// 唯一入口：widget 按钮点击 / 窗口已开着时再次点击（换 scope）都经这里，与
    /// `DailyDetailModel.reload()` 同一设计取舍——不依赖 AppKit key/active 通知时序。
    func show(scopeID: String) {
        pollTimer?.invalidate()
        pollTimer = nil

        self.scopeID = scopeID
        self.brief = nil
        self.windowTitle = MailSummaryScopeResolver.resolve(scopeID: scopeID, snapshot: SnapshotStore.load()) ?? scopeID
        refresh()

        if isGenerating {
            startPolling()
        } else if brief == nil {
            triggerGenerate()
        }
    }

    /// 「重新总结」按钮：不管有没有缓存，强制再跑一次。已经在生成中就什么都不做——
    /// 客户端这层防连点，真正的防重入仍然是 `MailSummarizer` 那边的 App Group 时间戳。
    func regenerate() {
        guard !isGenerating else { return }
        triggerGenerate()
    }

    /// 读缓存 + 读生成中 flag + 读上次错误，三者都是"当前权威状态"，每次都全量刷新，
    /// 不做增量比较——数据量小（每次 store.load 至多 20 条），没必要为这点数据搭
    /// diff 逻辑。`brief == nil`（从未生成过）与"生成过但 items 为空"（真实的空
    /// 总结，见 `MailSummarizer.summarize` 的空邮箱分支）在这里被小心区分开——
    /// 后者不该被 `show(scopeID:)` 误判成"没有缓存"再触发一次多余的生成。
    private func refresh() {
        isGenerating = MailSummarizer.isGenerating(scopeID: scopeID, now: Date())
        lastError = Self.sharedDefaults?.string(forKey: MailSummarizer.lastErrorKey(forScopeID: scopeID))
        do {
            if let loaded = try store.load(scopeID: scopeID) {
                brief = MailSummaryBrief.resolve(summary: loaded, snapshot: SnapshotStore.load())
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 分钟级同步调用，绝不能在主线程跑——SwiftUI 会整体冻结、窗口拖不动。丢到后台
    /// 队列，回来时校验 `scopeID` 没有在等待期间被换掉（用户切换/重开窗口）才写回。
    private func triggerGenerate() {
        let targetScope = scopeID
        isGenerating = true
        startPolling()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = MailSummarizer.summarize(scopeID: targetScope)
            DispatchQueue.main.async {
                guard let self, self.scopeID == targetScope else { return }
                self.refresh()
                self.stopPollingIfIdle()
            }
        }
    }

    /// 生成中时轮询——不只是等自己发起的这次后台任务：launchd 自动化跑在另一个
    /// 进程里，同样会写 App Group 里的 flag 和 store 文件，这个窗口开着的时候也要
    /// 能看到它跑完。
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.stopPollingIfIdle()
        }
    }

    private func stopPollingIfIdle() {
        guard !isGenerating else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
    }
}

/// 薄封装：只负责把 `model` 的 `@Published` 状态转发给 `MailSummaryContentView`。
struct MailSummaryView: View {
    @ObservedObject var model: MailSummaryModel

    var body: some View {
        MailSummaryContentView(
            scopeID: model.scopeID,
            windowTitle: model.windowTitle,
            brief: model.brief,
            isGenerating: model.isGenerating,
            lastError: model.lastError,
            onRegenerate: { model.regenerate() }
        )
    }
}

/// 纯渲染视图：不读 `SnapshotStore`、不读 App Group defaults、不触发生成——
/// 所有需要的数据都是入参。见文件顶部注释：这是为了让渲染验证 harness 能直接
/// 用手造 fixture 构造它。
struct MailSummaryContentView: View {
    let scopeID: String
    let windowTitle: String
    let brief: MailSummaryBrief?
    let isGenerating: Bool
    let lastError: String?
    let onRegenerate: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetTheme.sectionSpacingLarge) {
            header
            Divider()
            content
        }
        .padding(WidgetTheme.paddingLarge + 8)
        .frame(minWidth: 520, minHeight: 460)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(windowTitle.isEmpty ? "邮件总结" : windowTitle)
                    .font(.title3.weight(.semibold))
                if let date = brief?.generatedAt {
                    Text(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            regenerateControl
            MailSummaryAutomationButton(currentScopeID: scopeID)
        }
    }

    @ViewBuilder
    private var regenerateControl: some View {
        if isGenerating {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("生成中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button(action: onRegenerate) {
                Label("重新总结", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let brief, !brief.items.isEmpty {
            itemList(brief.items)
        } else if isGenerating {
            ContentUnavailableView(
                "正在生成邮件总结…",
                systemImage: "sparkles",
                description: Text("首次总结可能需要几分钟，取决于邮件数量。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let lastError {
            ContentUnavailableView(
                "总结失败",
                systemImage: "exclamationmark.triangle",
                description: Text(lastError)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "还没有总结",
                systemImage: "text.magnifyingglass",
                description: Text("点击「重新总结」生成一份。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func itemList(_ items: [MailSummaryDisplayItem]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: WidgetTheme.rowSpacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, display in
                    MailSummaryRow(display: display)
                    if index < items.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 一行：未读蓝点 + AI 中文标题 + 概要 +「发件人 · 相对时间」小字。刻意不显示原始
/// subject（2026-07-30 用户决定，`DailyDetailView.DetailBriefCard` 同一决定的
/// 注释里有完整背景：AI 中文标题和原始主题并排看着像挂错了邮件）。
///
/// `display.message` 关联不到时（Mail 本地没同步到这封信，或还没刷新过快照）
/// 未读点不亮、相对时间省略，只显示发件人——不是错误状态，只是快照暂时没有这份
/// 信息。
private struct MailSummaryRow: View {
    let display: MailSummaryDisplayItem

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        Button {
            openInMail()
        } label: {
            summaryBlock
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
    }

    private var summaryBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    unreadDot
                    Text(display.item.summaryTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Text(display.item.summaryDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(metaText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
    }

    /// 未读时是 MailWidget 同款实心点；已读/关联不到保留等宽透明占位，标题不会跟着
    /// 左右跳（与 `DailyDetailView.DetailBriefCard.unreadDot` 同一处理）。
    private var unreadDot: some View {
        Circle()
            .fill(display.isUnread ? Color.accentColor : Color.clear)
            .frame(width: 7, height: 7)
    }

    private var metaText: String {
        guard let message = display.message else { return display.item.sender }
        let relative = Self.relativeFormatter.localizedString(for: message.date, relativeTo: Date())
        return "\(display.item.sender) · \(relative)"
    }

    /// `messageIdHeader` 是契约 12 载荷的必填字段（每条总结都对应一封确切的信），
    /// 不像日报载荷那样需要 gmailURL 兜底。
    private func openInMail() {
        guard let url = MailMessageLink.url(forMessageIdHeader: display.item.messageIdHeader) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration)
        // 乐观已读：用户正要去 Mail 读它，未读点没必要等下一轮抓取才消失。
        SnapshotStore.applyLocalReadMark(messageIdHeader: display.item.messageIdHeader)
    }
}

/// 「⏰」打开一个设置面板（popover），不再点一下就直接装。面板内的 Toggle/时间/
/// 范围本身就是明确操作，不需要再弹一层确认框——原来的 `.confirmationDialog` 已按
/// 用户反馈去掉。
///
/// 状态短句只有两种颜色：secondary 灰色（当前的真实状态：已启用到几点几分，或未
/// 启用）、红色（上一次操作失败，只给"启用/停用/保存失败"这种短句，技术性细节
/// 留给 `~/Library/Logs/mailwidget-mail-summary.log`，不堆在 UI 里）。
///
/// 跟 `MailSummaryView`/`MailSummaryContentView` 同一个拆分理由：这个按钮自己持有
/// @State（真实的 Toggle 开关要触发真实的 install/uninstall I/O），但面板本身的
/// 渲染逻辑抽成下面无状态的 `MailSummaryAutomationPanelContent`——渲染验证 harness
/// 能直接用 `.constant(...)` 绑定灌固定状态，不用真的写 App Group defaults 或真的
/// 调 launchctl。
private struct MailSummaryAutomationButton: View {
    /// 总结窗口当前正在看的 scope——只在"从未配置过自动化"（`MailSummaryAutomationSettings
    /// .scopeID == nil`）时用作范围选择器的默认值；配置过之后，草稿状态一律从
    /// `MailSummaryAutomationSettings` 回读，不再受窗口切换 scope 影响。
    let currentScopeID: String

    private enum Action { case enable, disable, save }

    @State private var showPanel = false
    @State private var isEnabled = false
    @State private var hour = MailSummaryAutomationInstaller.defaultHour
    @State private var minute = MailSummaryAutomationInstaller.defaultMinute
    @State private var scopeID = MailScope.all
    @State private var isBusy = false
    @State private var failedAction: Action?

    var body: some View {
        Button {
            reloadFromSettings()
            showPanel = true
        } label: {
            Label("自动化", systemImage: "alarm")
                .labelStyle(.titleAndIcon)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("配置每日自动重新总结")
        .popover(isPresented: $showPanel, arrowEdge: .top) {
            MailSummaryAutomationPanelContent(
                statusText: statusText,
                statusIsError: failedAction != nil,
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
    /// 的这段时间被外部改动过（用户手动删了文件、或者另一次总结窗口的面板已经保存
    /// 过新配置）。`reconcileEnabledWithDisk()` 保证 `isEnabled` 不是过期的。
    private func reloadFromSettings() {
        isEnabled = MailSummaryAutomationSettings.reconcileEnabledWithDisk()
        hour = MailSummaryAutomationSettings.hour
        minute = MailSummaryAutomationSettings.minute
        scopeID = MailSummaryAutomationSettings.scopeID ?? currentScopeID
        failedAction = nil
    }

    /// Toggle 打开 与「保存」共用同一条装载路径——两者的语义都是"用当前面板草稿去
    /// (重新) 装载"，区别只是失败时该说"启用失败"还是"保存失败"。
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
    }

    private func performUninstall() {
        failedAction = nil
        isBusy = true
        MailSummaryAutomationInstaller.uninstall()
        isEnabled = false
        isBusy = false
    }
}

/// 纯渲染的面板内容：不读 `SnapshotStore`、不读/写 `MailSummaryAutomationSettings`、
/// 不调 `MailSummaryAutomationInstaller`——所有状态都是入参/绑定。渲染验证 harness
/// 用 `.constant(...)` 绑定 + 手造 `accountOptions` 就能重现任意面板状态。
struct MailSummaryAutomationPanelContent: View {
    let statusText: String
    let statusIsError: Bool
    let isEnabled: Binding<Bool>
    let time: Binding<Date>
    let scopeID: Binding<String>
    let accountOptions: [(id: String, name: String)]
    let isBusy: Bool
    let onToggle: (Bool) -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusIsError ? Color.red : Color.secondary)

            Toggle("每日自动总结", isOn: Binding(
                get: { isEnabled.wrappedValue },
                set: { onToggle($0) }
            ))
            .disabled(isBusy)

            DatePicker("运行时间", selection: time, displayedComponents: .hourAndMinute)
                .disabled(isBusy)

            Picker("总结范围", selection: scopeID) {
                Text("全部收件箱").tag(MailScope.all)
                ForEach(accountOptions, id: \.id) { option in
                    Text(option.name).tag(MailScope.accountPrefix + option.id)
                }
            }
            .disabled(isBusy)

            // 只在已启用时给「保存」——没启用的话改时间/范围只是在编辑草稿，
            // 真正生效的时机是打开 Toggle 那一刻（用当前草稿装载）。
            if isEnabled.wrappedValue {
                Button("保存", action: onSave)
                    .disabled(isBusy)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}
