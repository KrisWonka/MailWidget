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
            markAllReadButton
            if let pageInfo, pageInfo.totalPages > 1 {
                pageControls(pageInfo)
            }
            Text("\(unreadCount)")
                .font(.title2.weight(.bold))
                .foregroundStyle(unreadCount > 0 ? Color.accentColor : Color.secondary)
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
