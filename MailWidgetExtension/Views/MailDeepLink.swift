import Foundation

/// Contract 3/8 — deep links the widget uses to hand off to Mail.app / the host app.
enum MailDeepLink {
    /// Only characters that would actually break the URL get percent-encoded.
    /// `@ . + $` (all legal, common Message-ID characters) are left as-is —
    /// encoding `@` away is what silently broke deep links before.
    private static let allowedMessageIDCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~!$&'()*+,;=@")
        return set
    }()

    /// A single message: `message://<Message-ID>` (double slash — the
    /// community-verified stable form; a single slash silently no-ops on some
    /// Mail.app versions). `messageIdHeader` is the RFC Message-ID without angle
    /// brackets; Mail expects them percent-encoded as `%3C`/`%3E`.
    static func message(for messageIdHeader: String) -> URL? {
        guard let encoded = messageIdHeader.addingPercentEncoding(withAllowedCharacters: allowedMessageIDCharacters) else {
            return nil
        }
        return URL(string: "message://%3C\(encoded)%3E")
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
