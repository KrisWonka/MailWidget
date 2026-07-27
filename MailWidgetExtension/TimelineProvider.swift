import AppIntents
import WidgetKit
import SwiftUI

/// A message tagged with the account it came from — needed once a scope can span
/// multiple accounts (All Inboxes / VIP / Flagged), since each row's "no
/// Message-ID header, link to the mailbox instead" fallback (contract 8, item 4)
/// has to point at that message's own account, not the scope as a whole.
struct ScopedMessage {
    let accountID: String
    let message: MessageSummary
}

/// A scope (chosen via `MailWidgetConfigurationIntent`) resolved against the latest
/// snapshot into a single flattened view: a title to show in the header, a combined
/// unread count, an owning account (for the header's mailbox-name link — nil for
/// the All Inboxes / VIP / Flagged scopes, which have no single owning account),
/// and messages merged newest-first across every matching mailbox.
///
/// `unreadCount` is always the scope's true total — pagination only slices which
/// messages are visible, never the header's unread badge. `pageInfo` is nil for
/// families that don't paginate (Small/Medium); see `paginated(scopeID:pageSize:)`.
/// `scopeID` is the same string `ScopeResolver.resolve` was called with — the
/// header needs it (contract 11's "mark all read" button, alongside `PageInfo`
/// for pagination) regardless of whether this size paginates.
struct ResolvedScope {
    let title: String
    let unreadCount: Int
    let accountID: String?
    let messages: [ScopedMessage]
    let scopeID: String
    var pageInfo: PageInfo? = nil
}

extension ResolvedScope {
    /// Contract 9 — slices `messages` down to one page's worth for Large/XL,
    /// reading the current page from the same App Group UserDefaults key
    /// `MailPageIntent` writes to. `pageSize` nil means "don't paginate"
    /// (Small/Medium), in which case this is a no-op.
    func paginated(scopeID: String, pageSize: Int?) -> ResolvedScope {
        guard let pageSize, pageSize > 0, !messages.isEmpty else { return self }

        let totalPages = max(1, (messages.count + pageSize - 1) / pageSize)
        let requestedPage = PageState.currentPage(forScopeID: scopeID)
        let currentPage = min(max(requestedPage, 0), totalPages - 1)

        let start = currentPage * pageSize
        let end = min(start + pageSize, messages.count)
        let pageMessages = start < end ? Array(messages[start..<end]) : []

        return ResolvedScope(
            title: title,
            unreadCount: unreadCount,
            accountID: accountID,
            messages: pageMessages,
            scopeID: scopeID,
            pageInfo: PageInfo(scopeID: scopeID, currentPage: currentPage, totalPages: totalPages)
        )
    }
}

enum ScopeResolver {
    static func resolve(scopeID: String, snapshot: MailSnapshot) -> ResolvedScope {
        switch scopeID {
        case MailScopeEntity.vipScopeID:
            return resolveByRole("vip", title: "VIP", scopeID: MailScopeEntity.vipScopeID, snapshot: snapshot)
        case MailScopeEntity.flaggedScopeID:
            return resolveByRole("flagged", title: "Flagged", scopeID: MailScopeEntity.flaggedScopeID, snapshot: snapshot)
        case let id where id.hasPrefix(MailScopeEntity.accountPrefix):
            let accountID = String(id.dropFirst(MailScopeEntity.accountPrefix.count))
            guard let account = snapshot.accounts.first(where: { $0.id == accountID }) else {
                return resolveAll(snapshot: snapshot)
            }
            let inboxes = account.mailboxes.filter { $0.role == "inbox" }
            return merge(inboxes, accountID: account.id, title: account.name, scopeID: id)
        default:
            return resolveAll(snapshot: snapshot)
        }
    }

    /// Used both for the literal "all" scope and as the fallback when a
    /// configured scope no longer resolves (missing account, unrecognized
    /// string) — in every case the *content* actually shown is All Inboxes, so
    /// `scopeID` is set to `.allScopeID` here too, matching what's on screen
    /// rather than whatever the caller originally asked for.
    private static func resolveAll(snapshot: MailSnapshot) -> ResolvedScope {
        mergeAcrossAccounts(role: "inbox", title: "All Inboxes", scopeID: MailScopeEntity.allScopeID, snapshot: snapshot)
    }

    private static func resolveByRole(_ role: String, title: String, scopeID: String, snapshot: MailSnapshot) -> ResolvedScope {
        mergeAcrossAccounts(role: role, title: title, scopeID: scopeID, snapshot: snapshot)
    }

    /// Merges a role across every account, tagging each message with its own
    /// account — the resulting scope has no single owning account (`accountID: nil`).
    private static func mergeAcrossAccounts(role: String, title: String, scopeID: String, snapshot: MailSnapshot) -> ResolvedScope {
        var unreadCount = 0
        var scoped: [ScopedMessage] = []
        for account in snapshot.accounts {
            let mailboxes = account.mailboxes.filter { $0.role == role }
            unreadCount += mailboxes.reduce(0) { $0 + $1.unreadCount }
            scoped += mailboxes.flatMap { $0.messages }.map { ScopedMessage(accountID: account.id, message: $0) }
        }
        scoped.sort { $0.message.date > $1.message.date }
        return ResolvedScope(title: title, unreadCount: unreadCount, accountID: nil, messages: scoped, scopeID: scopeID)
    }

    /// Merges mailboxes that all belong to one account — every message is tagged
    /// with that same account, which also becomes the scope's owning account.
    private static func merge(_ mailboxes: [MailboxSummary], accountID: String, title: String, scopeID: String) -> ResolvedScope {
        let unreadCount = mailboxes.reduce(0) { $0 + $1.unreadCount }
        let scoped = mailboxes.flatMap { $0.messages }
            .map { ScopedMessage(accountID: accountID, message: $0) }
            .sorted { $0.message.date > $1.message.date }
        return ResolvedScope(title: title, unreadCount: unreadCount, accountID: accountID, messages: scoped, scopeID: scopeID)
    }
}

struct MailWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: MailSnapshot?
    let resolvedScope: ResolvedScope?

    /// A plausible, non-empty entry used only for the widget gallery placeholder.
    /// WidgetKit redacts this automatically, so real-looking sample text is fine.
    static var placeholder: MailWidgetEntry {
        let sample = [
            ScopedMessage(accountID: "placeholder-account", message: MessageSummary(id: "placeholder-1", messageIdHeader: nil, sender: "Sarah Chen", senderEmail: "sarah@example.com", subject: "Q3 planning doc", snippet: "Could you leave comments by Friday…", date: Date(), isRead: false, isFlagged: false)),
            ScopedMessage(accountID: "placeholder-account", message: MessageSummary(id: "placeholder-2", messageIdHeader: nil, sender: "GitHub", senderEmail: "notifications@github.com", subject: "PR #12 merged", snippet: "3 checks passed…", date: Date().addingTimeInterval(-3600), isRead: false, isFlagged: false)),
        ]
        return MailWidgetEntry(
            date: Date(),
            snapshot: nil,
            resolvedScope: ResolvedScope(title: "All Inboxes", unreadCount: 3, accountID: nil, messages: sample, scopeID: MailScopeEntity.allScopeID)
        )
    }
}

struct MailTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = MailWidgetEntry
    typealias Intent = MailWidgetConfigurationIntent

    func placeholder(in context: Context) -> MailWidgetEntry {
        .placeholder
    }

    func snapshot(for configuration: MailWidgetConfigurationIntent, in context: Context) async -> MailWidgetEntry {
        if context.isPreview {
            return .placeholder
        }
        return makeEntry(configuration: configuration, family: context.family)
    }

    func timeline(for configuration: MailWidgetConfigurationIntent, in context: Context) async -> Timeline<MailWidgetEntry> {
        let entry = makeEntry(configuration: configuration, family: context.family)
        // The host app drives real refreshes via WidgetCenter.reloadAllTimelines();
        // this 15-minute entry just guarantees the "data may be stale" badge stays
        // accurate even if the host app is quit for a while.
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func makeEntry(configuration: MailWidgetConfigurationIntent, family: WidgetFamily) -> MailWidgetEntry {
        guard let snapshot = SnapshotStore.load() else {
            return MailWidgetEntry(date: Date(), snapshot: nil, resolvedScope: nil)
        }
        let scopeID = configuration.scope.id
        var resolved = ScopeResolver.resolve(scopeID: scopeID, snapshot: snapshot)
        if let pageSize = Self.pageSize(for: family) {
            resolved = resolved.paginated(scopeID: scopeID, pageSize: pageSize)
        }
        return MailWidgetEntry(date: Date(), snapshot: snapshot, resolvedScope: resolved)
    }

    /// Contract 9 — page sizes match each size's largest `ViewThatFits` candidate
    /// (Large: single column of 6; XL: two columns of 6 = 12 total). Small/Medium
    /// return nil (no pagination this round). What's actually visible within a
    /// page is still up to that view's own `ViewThatFits` ladder.
    private static func pageSize(for family: WidgetFamily) -> Int? {
        switch family {
        case .systemLarge:
            return 6
        default:
            if #available(macOS 14.0, *), family == .systemExtraLarge {
                return 12
            }
            return nil
        }
    }
}

struct MailWidget: Widget {
    let kind: String = "MailWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: MailWidgetConfigurationIntent.self,
            provider: MailTimelineProvider()
        ) { entry in
            MailWidgetView(entry: entry)
        }
        .configurationDisplayName("MailWidget")
        .description("Shows unread mail from your Mac's Mail app.")
        .supportedFamilies(supportedWidgetFamilies)
    }

    /// `.systemExtraLarge` is annotated available since macOS 14.0 in this SDK — the
    /// same as our deployment target — so this guard is always-true today. Kept per
    /// spec's instruction so a future lower deployment target (or a system where the
    /// desktop widget gallery doesn't actually offer XL) degrades gracefully instead
    /// of failing to build or over-registering an unsupported family.
    private var supportedWidgetFamilies: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
        if #available(macOS 14.0, *) {
            families.append(.systemExtraLarge)
        }
        return families
    }
}
