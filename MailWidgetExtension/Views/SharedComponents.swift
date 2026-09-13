import SwiftUI

/// Shared header used by systemMedium/systemLarge/systemExtraLarge: mailbox name
/// (tappable — contract 8, item 3 — opens that mailbox in Mail.app), an optional
/// "mark all read" button (contract 11 — any size, when applicable), an optional
/// page-turn control (contract 9 — Large/XL only, via `pageInfo`), unread count,
/// and a "data may be stale" badge when the snapshot is >10 min old.
struct MailboxHeaderRow: View {
    let title: String
    let accountID: String?
    let scopeID: String
    let unreadCount: Int
    let generatedAt: Date?
    var pageInfo: PageInfo? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                titleView
                if isStale {
                    Label("Data may be out of date", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            mailSummaryButton
            markAllReadButton
            if let pageInfo, pageInfo.totalPages > 1 {
                pageControls(pageInfo)
            }
            Text("\(unreadCount)")
                .font(.title2.weight(.bold))
                .foregroundStyle(unreadCount > 0 ? Color.accentColor : Color.secondary)
        }
    }

    /// Contract 12 — sits to the left of the "mark all read" envelope. Opens the
    /// host app's mail-summary window for this scope. Same scope restriction as
    /// `markAllReadButton` (all/account only — see `MailDeepLink.supportsMailSummary`),
    /// but shown regardless of unread count: a summary is useful even once
    /// everything's read.
    @ViewBuilder
    private var mailSummaryButton: some View {
        if MailDeepLink.supportsMailSummary(scopeID: scopeID),
           let url = MailDeepLink.mailSummary(scopeID: scopeID) {
            Link(destination: url) {
                Image(systemName: "list.bullet.rectangle")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Sits to the left of the page controls (contract 11). Only offered for
    /// scopes where "mark everything read" has one clear meaning — see
    /// `MailDeepLink.supportsMarkAllRead` — and only when there's actually
    /// something unread to clear.
    @ViewBuilder
    private var markAllReadButton: some View {
        if unreadCount > 0,
           MailDeepLink.supportsMarkAllRead(scopeID: scopeID),
           let url = MailDeepLink.markAllRead(scopeID: scopeID) {
            Link(destination: url) {
                Image(systemName: "envelope.open")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var titleView: some View {
        let text = Text(title)
            .font(.headline)
            .lineLimit(1)
        if let url = MailDeepLink.mailbox(accountID: accountID) {
            Link(destination: url) { text }
                .buttonStyle(.plain)
        } else {
            text
        }
    }

    /// ▲ goes to the previous (lower-numbered) page, ▼ to the next. At either
    /// end, the button's own `targetPage` is clamped to the current page — a
    /// same-page tap is a no-op, so there's no need for a separate disabled state.
    @ViewBuilder
    private func pageControls(_ pageInfo: PageInfo) -> some View {
        HStack(spacing: 4) {
            Button(intent: MailPageIntent(scopeID: pageInfo.scopeID, targetPage: max(pageInfo.currentPage - 1, 0))) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)

            Text("\(pageInfo.currentPage + 1)/\(pageInfo.totalPages)")
                .foregroundStyle(.secondary)

            Button(intent: MailPageIntent(scopeID: pageInfo.scopeID, targetPage: min(pageInfo.currentPage + 1, pageInfo.totalPages - 1))) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
    }

    private var isStale: Bool {
        guard let generatedAt else { return false }
        return Date().timeIntervalSince(generatedAt) > 10 * 60
    }
}

/// Shown when a resolved scope has zero messages (mailbox exists, nothing unread /
/// nothing to show) — distinct from the "never configured" empty state below.
struct InboxZeroView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No unread mail")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }
}

/// Shown when `SnapshotStore.load()` returns nil — MailWidget has never produced a
/// snapshot yet (contract 2).
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "envelope.badge")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open MailWidget to finish setup")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 真机部署实录：Mail.app 里一个真实邮件账户都没有（只有本地 Drafts/Outbox）时，
/// `ProviderProbe.hasConfiguredMailAccounts()` 探测得到的快照 `accounts` 是空数组，
/// 抓取本身并不会失败——于是这种情况原本会落进 `EmptyStateView`（快照从未生成，
/// 提示"打开 MailWidget 完成设置"）或 `InboxZeroView`（有账户但没有未读，提示
/// "全部已读"）之一，两者都会误导用户：真正要做的是去「邮件」App 加一个账户，
/// 不是重新设置本 app，也不是"恭喜全部读完"。
///
/// Widget extension 是沙盒进程，读不到 `~/Library/Mail`，这个判断本身不能在这里做，
/// 只能读宿主 app 写进 App Group 的结论——见 `MailAccountStatusReader`。
struct NoMailAccountsView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("邮件 App 里还没有账户")
                .font(.caption)
                .multilineTextAlignment(.center)
            Text("打开「邮件」App 添加一个邮箱账户")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 与宿主 app 那份 `MailAccountStatusPublisher.hasConfiguredMailAccountsKey`
/// （`MailWidgetApp/MailAccountStatusPublisher.swift`）必须完全一致的字符串
/// 字面量。两个 target 各自独立编译，DataKit 是唯一横跨两边的共享代码，但这次
/// 改动的边界不允许碰 DataKit，只能在两侧各写一份、靠这条注释互相指认防止漂移。
private enum MailAccountStatusKey {
    static let hasConfiguredMailAccounts = "hasConfiguredMailAccounts"
}

/// 读宿主 app 写进 App Group 的「Mail.app 有没有配置真实邮件账户」结论。Widget
/// extension 沙盒进程读不到 `~/Library/Mail`，这个判断必须由宿主 app
/// （`MailAccountStatusPublisher`）算好写进这个键，这里只读——不调用
/// `ProviderProbe` 本体。
enum MailAccountStatusReader {
    /// nil = 键还没写过（宿主 app 从没启动过一次、或者是很旧的构建产物、或者是
    /// 渲染验证 harness 这种没有真实 App Group 容器的环境）——拿不准的时候不要显示
    /// "没有账户"这种更具体但可能是错的文案，宁可退回更保守的通用空态
    /// （`EmptyStateView`），也不要在"其实有账户，只是宿主还没来得及写这个键"的
    /// 情况下误报"没有账户"。
    static var hasConfiguredMailAccounts: Bool? {
        guard let defaults = UserDefaults(suiteName: SharedConstants.appGroupIdentifier),
              defaults.object(forKey: MailAccountStatusKey.hasConfiguredMailAccounts) != nil else {
            return nil
        }
        return defaults.bool(forKey: MailAccountStatusKey.hasConfiguredMailAccounts)
    }
}
