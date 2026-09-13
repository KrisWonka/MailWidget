import Darwin
import SwiftUI
import AppKit
import CoreServices

@main
struct MailWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 命令行 ingest 模式：外部 agent 调
    /// `MailWidget --ingest <json> [--source <id>]` 时，在 SwiftUI 建立任何 Scene
    /// 之前就处理完并退出。这样这次调用不会拉起菜单栏图标、不会启动 RefreshScheduler，
    /// 也不会干扰已经在跑的那个常驻实例。
    init() {
        if let exitCode = IngestCommand.runIfRequested(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            fflush(stdout)
            fflush(stderr)
            Darwin.exit(exitCode)
        }
        // 契约 12：`MailWidget --summarize <scopeID>`，同一先例——同步跑完就退出，
        // 不建立任何 Scene。
        if let exitCode = SummarizeCommand.runIfRequested(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            fflush(stdout)
            fflush(stderr)
            Darwin.exit(exitCode)
        }
    }

    var body: some Scene {
        MenuBarExtra("MailWidget", systemImage: "envelope.fill") {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

/// Handles the two things that don't fit cleanly into declarative `Scene`s:
/// kicking off the background refresh loop at launch, showing the first-run
/// Onboarding window, and routing `mailwidget://open` back into Mail.app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingWindow: NSWindow?
    private var dailyDetailWindow: NSWindow?
    /// 与 `dailyDetailWindow` 一样是单例，且必须比它活得一样久：窗口的
    /// `NSHostingView(rootView:)` 只在窗口首次创建时实例化一次，之后每次
    /// `showDailyDetailWindow()` 复用同一个窗口——如果 model 换成局部变量，第二次
    /// 打开时读到的还是第一次那份（可能缺 messageIdHeader 的）旧日报。
    private let dailyDetailModel = DailyDetailModel()
    private var mailSummaryWindow: NSWindow?
    /// 契约 12：与 `dailyDetailModel` 同一取舍——单例、必须和窗口活得一样久。
    private let mailSummaryModel = MailSummaryModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // P0 fix: SwiftUI's `App`/`Scene` lifecycle (MenuBarExtra included) installs
        // its own kAEGetURL Apple Event handler during setup, which silently
        // supersedes `NSApplicationDelegate.application(_:open:)` — that delegate
        // method is simply never called for a SwiftUI-lifecycle app. Registering our
        // own handler here (after SwiftUI's own registration has already happened,
        // since this runs from didFinishLaunching) makes ours win, since the last
        // handler registered for a given event class/ID is the one Apple Event
        // Manager dispatches to.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(Self.getURLEventClass),
            andEventID: AEEventID(Self.getURLEventID)
        )

        // 合并前 GmailDailyWidget 有自己的 App Group；把它最后一份日报搬进来，
        // 这样刚装好新版就能直接看到内容，而不是"等待第一份日报"。只跑一次，
        // 旧容器的文件保留不删。
        DailySummaryMigration.runIfNeeded()

        RefreshScheduler.shared.start()
        // 契约：收件箱 widget / 邮件总结在"Mail 里没有账户"时要能明确告知，而不是
        // 显示看起来像"全部已读"的空白——见 `MailAccountStatusPublisher` 顶部注释。
        MailAccountStatusPublisher.start()
        if Self.needsOnboarding {
            showOnboardingWindow()
            return
        }

        // 冷启动时给出可见反馈。本 app 是 LSUIElement：没有 Dock 图标、没有窗口，
        // 在 Spotlight 里点它如果什么都不弹，看上去就是"打不开"。
        //
        // 这里**不能**靠 `NSApp.isActive` 或 `applicationDidBecomeActive` 判断是不是
        // 用户主动打开的：LSUIElement app 被 `open` 拉起时 macOS 根本不会激活它
        // （实测冷启动后 7 秒最前台仍是别的 app、自身 frontmost 为 false），
        // 那两条路都永远不触发。前两次修复都栽在这个不成立的前提上。
        //
        // 可靠的区分是启动时那个 kAEOpenApplication 事件带没带
        // `keyAELaunchedAsLogInItem`——只有登录项启动才有。
        if !isLaunchedAsLoginItem {
            showDailyDetailWindow()
        }
    }

    /// 是否由登录项拉起。`currentAppleEvent` 在 didFinishLaunching 期间正是那个
    /// kAEOpenApplication 事件。
    private var isLaunchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else {
            return false
        }
        return event.paramDescriptor(forKeyword: keyAEPropData)?
            .enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// app 已在运行时用户又点了它（Spotlight / Finder / Dock）。LSUIElement 应用没有
    /// 窗口可以恢复，不接这个事件就等于"点了没反应"—— 合并前 GmailDailyWidget 是普通
    /// 窗口 app，点开必然有窗口，合并到菜单栏宿主后这个行为丢了。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            showDailyDetailWindow()
        }
        return true
    }

    /// Both the class and the ID for the "open URL" Apple Event are the four-char
    /// code 'GURL' — this is the actual stable OS-level constant apps have used for
    /// URL-scheme handling for decades. The named C constants for it
    /// (`kInternetEventClass`/`kAEGetURL`) aren't exposed in this SDK's headers, so
    /// the value is computed directly instead of referencing them.
    private static let getURLEventClass: UInt32 = fourCharCode("GURL")
    private static let getURLEventID: UInt32 = fourCharCode("GURL")

    private static func fourCharCode(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Primary path (P0 fix): SwiftUI never forwards this event to
    /// `application(_:open:)`, so we register directly with `NSAppleEventManager`
    /// and unpack the URL string from the event's direct-object parameter ourselves.
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        handle(url)
    }

    /// Contract 3/8: the widget's card-level tap opens `mailwidget://open`, and a
    /// mailbox-name header or Message-ID-less message row opens
    /// `mailwidget://openMailbox?accountId=<id>`. Kept as a second path in case a
    /// future macOS/SwiftUI version restores this delegate callback for custom
    /// URL schemes — see `handleGetURLEvent(_:withReplyEvent:)` above for why this
    /// alone isn't sufficient today.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "mailwidget" {
            handle(url)
        }
    }

    private func handle(_ url: URL) {
        NSLog("%@", "MailWidget: handling URL " + url.absoluteString)

        // macOS delivers every URL a widget's Link opens to the widget's owning
        // app's kAEGetURL handler, regardless of scheme — not just our own
        // `mailwidget://` ones. A message row's `message://%3C...%3E` deep link
        // (contract 3) lands here too; anything that isn't our own scheme just
        // needs to be handed to the system to route to its real owner (Mail.app).
        guard url.scheme?.lowercased() == "mailwidget" else {
            // Contract 10: optimistic read-mark. The user is about to read this
            // message in Mail (we're forwarding them there right now), so clear
            // its unread dot in the snapshot immediately rather than waiting up
            // to the full refresh interval for the next poll to notice. This is
            // "optimistic" — Mail is the source of truth, and RefreshScheduler's
            // Envelope Index-wal watch reconciles it for real shortly after.
            if url.scheme?.lowercased() == "message", let messageIdHeader = Self.messageIdHeader(from: url) {
                SnapshotStore.applyLocalReadMark(messageIdHeader: messageIdHeader)
            }

            // Plain `open(_:)` doesn't carry an activation token for an
            // LSUIElement app, so the target app (Mail) opens its window in the
            // background and never comes to the front. `activates = true` fixes
            // that; fire-and-forget is fine here, no completion handling needed.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(url, configuration: configuration)
            return
        }

        guard let host = url.host?.lowercased() else { return }
        switch host {
        case "open":
            MailAppOpener.openMailbox(accountName: nil)
        case "openmailbox":
            let accountID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "accountId" })?.value
            let accountName = accountID.flatMap { id in
                SnapshotStore.load()?.accounts.first(where: { $0.id == id })?.name
            }
            MailAppOpener.openMailbox(accountName: accountName)
        case "dailydetail":
            showDailyDetailWindow()
        case "regeneratedaily":
            DailyRegenerator.regenerate()
        case "markallread":
            guard let scope = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "scope" })?.value else { return }
            // Contract 11: optimistic snapshot update first (instant unread-dot
            // clear), then the real batch mark-read in Mail — same
            // optimistic-then-reconcile shape as the single-message read mark above.
            SnapshotStore.applyLocalMarkAllRead(scopeID: scope)
            // Batch-1 review fix (High #1): this endpoint is reachable from any
            // local process or web page that can open a `mailwidget://` URL, so an
            // unrecognized scope must fail closed — do nothing — rather than fall
            // back to "every account" the way the old `accountNames(forScope:)`
            // (which folded parse failure and "all" into the same `nil`) did.
            guard let target = Self.markAllReadTarget(forScope: scope) else {
                NSLog("%@", "MailWidget: markAllRead rejected for unrecognized scope \"\(scope)\" (fail-closed)")
                return
            }
            MailAppOpener.markAllRead(target)
        case "mailsummary":
            guard let scope = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "scope" })?.value else { return }
            // Contract 12: same fail-closed shape as markAllRead above — an
            // unrecognized scope (or an `account:` id that no longer exists in the
            // snapshot) must not open the window at all, not silently fall back to
            // "all". `MailSummaryScopeResolver` is the single judgment call shared
            // with `MailSummaryModel`'s own scope-name lookup, so this can't drift
            // from what the window itself considers valid.
            guard MailSummaryScopeResolver.resolve(scopeID: scope, snapshot: SnapshotStore.load()) != nil else {
                NSLog("%@", "MailWidget: mailSummary rejected for unrecognized scope \"\(scope)\" (fail-closed)")
                return
            }
            showMailSummaryWindow(scopeID: scope)
        default:
            break
        }
    }

    /// Fail-closed scope → `MarkAllReadTarget` resolution. `scope` uses the same
    /// string format as `MailScopeEntity` on the widget side ("all" / "account:<id>")
    /// — that type lives in the extension target, not this one, so `DataKit`'s
    /// `MailScope` constants (compiled into both targets) are the shared source of
    /// truth instead of a second copy of the literals here.
    ///
    /// Returns nil — meaning "do nothing" — for anything that isn't exactly
    /// `MailScope.all`, or an `account:`-prefixed scope that fails to resolve to a
    /// real account in the current snapshot. VIP/Flagged and any other garbage
    /// scope are deliberately not handled here (`MailDeepLink.supportsMarkAllRead`
    /// never offers the button for them on the widget side either), and an
    /// `account:` scope with an ID that no longer exists in the snapshot must not
    /// silently widen to "every account".
    private static func markAllReadTarget(forScope scope: String) -> MarkAllReadTarget? {
        if scope == MailScope.all {
            return .allAccounts
        }
        guard scope.hasPrefix(MailScope.accountPrefix) else { return nil }
        let accountID = String(scope.dropFirst(MailScope.accountPrefix.count))
        guard let name = SnapshotStore.load()?.accounts.first(where: { $0.id == accountID })?.name else {
            return nil
        }
        return .accounts([name])
    }

    /// Recovers the bare RFC Message-ID from a `message://%3C...%3E` deep link:
    /// strip the scheme prefix, undo the percent-encoding `MailDeepLink` applied,
    /// then trim the surrounding angle brackets Mail's URL scheme expects.
    private static func messageIdHeader(from url: URL) -> String? {
        let prefix = "message://"
        guard url.absoluteString.hasPrefix(prefix) else { return nil }
        let encoded = String(url.absoluteString.dropFirst(prefix.count))
        guard var id = encoded.removingPercentEncoding else { return nil }
        if id.hasPrefix("<") { id.removeFirst() }
        if id.hasSuffix(">") { id.removeLast() }
        return id.isEmpty ? nil : id
    }

    /// 日报详细页面。宿主是 LSUIElement（无 Dock 图标），所以窗口手工创建，
    /// 与 Onboarding 同一套做法；`isReleasedWhenClosed = false` 让它可以反复打开。
    ///
    /// `dailyDetailModel.reload()` 放在最前面、每次调用本函数都无条件跑一次——不依赖
    /// AppKit 的 key/active 通知时序。这是本函数（详情按钮 / Dock 图标 reopen / 冷启动
    /// 首次）作为"要把这个窗口给用户看"的唯一入口，天然覆盖了"窗口复用、第二次打开"
    /// 这个此前会显示陈旧日报（缺 messageIdHeader）的场景。
    private func showDailyDetailWindow() {
        dailyDetailModel.reload()
        if dailyDetailWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Gmail 日报"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: DailyDetailView(model: dailyDetailModel))
            dailyDetailWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        dailyDetailWindow?.makeKeyAndOrderFront(nil)
    }

    /// 契约 12 — 邮件总结窗口。同 `showDailyDetailWindow()` 的取舍：`mailSummaryModel
    /// .show(scopeID:)` 放在最前面、每次调用本函数都无条件跑一次，不依赖 AppKit
    /// key/active 通知时序——这是"要把这个窗口给用户看"的唯一入口（widget 按钮），
    /// 天然覆盖"窗口复用、换 scope 再次打开"的场景。
    /// Not `private` — `SettingsView`'s new 邮件总结 Section (「配置…」/「打开总结窗口」
    /// buttons) calls this directly via `NSApp.delegate as? AppDelegate` instead of
    /// round-tripping through a self-addressed `mailwidget://` URL, since both live in
    /// the same process.
    func showMailSummaryWindow(scopeID: String) {
        mailSummaryModel.show(scopeID: scopeID)
        if mailSummaryWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "邮件总结"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: MailSummaryView(model: mailSummaryModel))
            mailSummaryWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mailSummaryWindow?.makeKeyAndOrderFront(nil)
    }

    /// 去个人化后弹出条件从"快照为 nil"扩为三种任一成立：还没有快照（首次
    /// 启动）、日报邮箱没配置、或本机 claude/codex 两个 CLI 都探测不到。三种
    /// 情形单独看都会让朋友装完之后一脸茫然——快照会在首次刷新后很快出现，但
    /// 邮箱和 CLI 不配置就永远不会自己出现，必须主动弹一次引导，而不是安静地
    /// 假装配置好了。
    private static var needsOnboarding: Bool {
        if SnapshotStore.load() == nil { return true }
        let mailbox = DailySummaryConstants.configuredMailbox?.trimmingCharacters(in: .whitespacesAndNewlines)
        if mailbox == nil || mailbox!.isEmpty { return true }
        if !AgentCLILocator.isInstalled(.claude) && !AgentCLILocator.isInstalled(.codex) { return true }
        return false
    }

    /// Not `private` — `SettingsView`'s「重新打开配置向导」按钮 calls this
    /// directly via `NSApp.delegate as? AppDelegate`, same shape as
    /// `showMailSummaryWindow(scopeID:)` above.
    func showOnboardingWindow() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to MailWidget"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: OnboardingView())
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

/// The MenuBarExtra dropdown: total unread count, a per-account breakdown,
/// "Refresh Now", "Settings…", and "Quit".
private struct MenuBarContentView: View {
    @State private var snapshot: MailSnapshot?
    @State private var isRefreshing = false

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            totalUnreadHeader
            Divider()
            accountsList
            Divider()
            actionButtons
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { reload() }
        .onReceive(refreshTimer) { _ in reload() }
    }

    private var totalUnreadCount: Int {
        guard let snapshot else { return 0 }
        return snapshot.accounts.reduce(0) { $0 + unreadCount(for: $1) }
    }

    private var totalUnreadHeader: some View {
        HStack {
            Image(systemName: "envelope.fill")
                .foregroundStyle(Color.accentColor)
            Text("\(totalUnreadCount) unread")
                .font(.headline)
            Spacer()
        }
    }

    @ViewBuilder
    private var accountsList: some View {
        if let snapshot, !snapshot.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.accounts, id: \.id) { account in
                    HStack {
                        Text(account.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Text("\(unreadCount(for: account))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text("No accounts yet — open Settings to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func unreadCount(for account: AccountSummary) -> Int {
        account.mailboxes.filter { $0.role == "inbox" }.reduce(0) { $0 + $1.unreadCount }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await refreshNow() }
            } label: {
                Label(isRefreshing ? "Refreshing…" : "Refresh Now", systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)

            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit MailWidget", systemImage: "power")
            }
        }
        .buttonStyle(.plain)
    }

    private func reload() {
        snapshot = SnapshotStore.load()
    }

    private func refreshNow() async {
        isRefreshing = true
        _ = await RefreshScheduler.shared.refreshNow()
        // 顺带把"Mail 有没有账户"这个结论也重新探测一次——用户手动点"立即刷新"
        // 通常正是因为刚去 Mail App 改过点什么（比如刚加完账户）。
        MailAccountStatusPublisher.refresh()
        reload()
        isRefreshing = false
    }
}
