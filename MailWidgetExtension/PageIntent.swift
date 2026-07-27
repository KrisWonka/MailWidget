import AppIntents
import WidgetKit

/// Contract 9 — Large/systemExtraLarge page through a scope's message list since
/// WidgetKit views can't scroll. The target page is computed at render time (in
/// `TimelineProvider`) and baked directly into the intent instance passed to
/// `Button(intent:)`; AppIntents parameters are serialized as part of
/// constructing that intent value, which is the standard, supported way to carry
/// render-time state into `perform()` — no extra plumbing required.
///
/// This is a plain `AppIntent`, not a `WidgetConfigurationIntent`: the protocol's
/// default `openAppWhenRun` is `false`, so tapping ▲/▼ runs `perform()` in the
/// widget extension process itself and never launches/foregrounds the host app.
struct MailPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Change Mail Widget Page"

    @Parameter(title: "Scope ID")
    var scopeID: String

    @Parameter(title: "Target Page")
    var targetPage: Int

    init() {
        self.scopeID = ""
        self.targetPage = 0
    }

    init(scopeID: String, targetPage: Int) {
        self.scopeID = scopeID
        self.targetPage = targetPage
    }

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
        defaults?.set(targetPage, forKey: PageState.key(forScopeID: scopeID))
        // Must match `MailWidget.kind` in TimelineProvider.swift.
        WidgetCenter.shared.reloadTimelines(ofKind: "MailWidget")
        return .result()
    }
}
