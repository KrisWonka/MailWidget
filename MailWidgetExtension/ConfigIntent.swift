import AppIntents
import WidgetKit

/// One selectable scope for a widget instance: all inboxes, a single account's inbox,
/// the VIP virtual mailbox, or the Flagged virtual mailbox. Options are enumerated
/// dynamically from the most recent `MailSnapshot` (contract 4) — never hardcoded,
/// since VIP/Flagged mailboxes may not exist in every snapshot.
struct MailScopeEntity: AppEntity {
    static let allScopeID = "all"
    static let vipScopeID = "vip"
    static let flaggedScopeID = "flagged"
    static let accountPrefix = "account:"

    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mailbox Scope"
    static var defaultQuery = MailScopeQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }

    static var allInboxes: MailScopeEntity {
        MailScopeEntity(id: allScopeID, name: "All Inboxes")
    }
}

struct MailScopeQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MailScopeEntity] {
        Self.availableScopes().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MailScopeEntity] {
        Self.availableScopes()
    }

    func defaultResult() async -> MailScopeEntity? {
        .allInboxes
    }

    /// Builds the option list from whatever the last snapshot actually contains.
    /// "All Inboxes" is always offered; per-account, VIP, and Flagged options only
    /// appear when the snapshot has a mailbox with that role.
    static func availableScopes() -> [MailScopeEntity] {
        var scopes: [MailScopeEntity] = [.allInboxes]
        guard let snapshot = SnapshotStore.load() else { return scopes }

        for account in snapshot.accounts {
            scopes.append(MailScopeEntity(id: "\(MailScopeEntity.accountPrefix)\(account.id)", name: account.name))
        }

        let hasVIP = snapshot.accounts.contains { account in
            account.mailboxes.contains { $0.role == "vip" }
        }
        if hasVIP {
            scopes.append(MailScopeEntity(id: MailScopeEntity.vipScopeID, name: "VIP"))
        }

        let hasFlagged = snapshot.accounts.contains { account in
            account.mailboxes.contains { $0.role == "flagged" }
        }
        if hasFlagged {
            scopes.append(MailScopeEntity(id: MailScopeEntity.flaggedScopeID, name: "Flagged"))
        }

        return scopes
    }
}

struct MailWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Mailbox Scope"
    static var description = IntentDescription("Choose which mailboxes this widget shows.")

    // No compile-time `default:` here — AppEntity parameters require the default to
    // be a literal, not an expression. `MailScopeQuery.defaultResult()` (= .allInboxes)
    // supplies the runtime default instead.
    @Parameter(title: "Scope")
    var scope: MailScopeEntity
}
