import Foundation

/// Contract 3/8 — deep links the widget uses to hand off to Mail.app / the host app.
enum MailDeepLink {
    /// A single message: `message://<Message-ID>`. The construction (including the
    /// percent-encoding rules that `@` must survive) lives in DataKit's
    /// `MailMessageLink` so the host app's daily-brief detail window builds byte
    /// identical URLs instead of keeping a second copy that can drift.
    static func message(for messageIdHeader: String) -> URL? {
        MailMessageLink.url(forMessageIdHeader: messageIdHeader)
    }

    /// Contract 8 — routes through the host app's URL scheme, which resolves
    /// `accountId` to an account name via `SnapshotStore.load()` and calls
    /// `MailAppOpener.openMailbox(accountName:)`. Used both by the clickable
    /// mailbox-name header and by any message row that has no `messageIdHeader`
    /// to link to directly (contract 8, item 4) — `accountID` is nil only for the
    /// All Inboxes / VIP / Flagged scopes, which have no single owning account.
    static func mailbox(accountID: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "mailwidget"
        components.host = "openMailbox"
        if let accountID, !accountID.isEmpty {
            components.queryItems = [URLQueryItem(name: "accountId", value: accountID)]
        }
        return components.url
    }

    /// Contract 11 — only the All Inboxes scope and a single account's inbox have
    /// one unambiguous meaning of "mark everything read"; VIP/Flagged are
    /// cross-cutting views of messages that really live in other mailboxes, so
    /// the header's "mark all read" button doesn't offer itself there.
    static func supportsMarkAllRead(scopeID: String) -> Bool {
        scopeID == MailScopeEntity.allScopeID || scopeID.hasPrefix(MailScopeEntity.accountPrefix)
    }

    /// Routes through the host app, which does the actual optimistic snapshot
    /// update (`SnapshotStore.applyLocalMarkAllRead`) and the real batch mark-read
    /// in Mail (`MailAppOpener.markAllRead`).
    static func markAllRead(scopeID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailwidget"
        components.host = "markAllRead"
        components.queryItems = [URLQueryItem(name: "scope", value: scopeID)]
        return components.url
    }
}
