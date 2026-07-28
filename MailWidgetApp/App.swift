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
        if SnapshotStore.load() == nil {
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
        case "markallread":
            guard let scope = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "scope" })?.value else { return }
            // Contract 11: optimistic snapshot update first (instant unread-dot
            // clear), then the real batch mark-read in Mail — same
            // optimistic-then-reconcile shape as the single-message read mark above.
            SnapshotStore.applyLocalMarkAllRead(scopeID: scope)
            MailAppOpener.markAllRead(accountNames: Self.accountNames(forScope: scope))
        default:
            break
        }
    }

    /// `scope` uses the same string format as `MailScopeEntity` on the widget
    /// side ("all" / "account:<id>") — that type lives in the extension target,
    /// not this one, so the "account:" prefix is matched here as a literal
    /// rather than shared. `"all"` (or anything else that isn't "account:...")
    /// maps to nil, meaning "every account" to `MailAppOpener.markAllRead`.
    private static func accountNames(forScope scope: String) -> [String]? {
        let accountPrefix = "account:"
        guard scope.hasPrefix(accountPrefix) else { return nil }
        let accountID = String(scope.dropFirst(accountPrefix.count))
        guard let name = SnapshotStore.load()?.accounts.first(where: { $0.id == accountID })?.name else {
            return nil
        }
        return [name]
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
    private func showDailyDetailWindow() {
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
            window.contentView = NSHostingView(rootView: DailyDetailView())
            dailyDetailWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        dailyDetailWindow?.makeKeyAndOrderFront(nil)
    }

    private func showOnboardingWindow() {
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
        reload()
        isRefreshing = false
    }
}
