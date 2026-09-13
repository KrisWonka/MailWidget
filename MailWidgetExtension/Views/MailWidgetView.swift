import SwiftUI
import WidgetKit

/// The single root view returned to `AppIntentConfiguration`'s content closure.
/// Applies `.containerBackground(for: .widget)` exactly once here (macOS 14+
/// hard requirement) and dispatches to the per-size layout based on the
/// environment's widget family.
struct MailWidgetView: View {
    let entry: MailWidgetEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // No card-level widgetURL: tapping blank space is a deliberate no-op —
        // only the mailbox name and message rows (each their own `Link`) should
        // do anything. Without a widgetURL, a background tap just activates this
        // widget's owning app, which for an LSUIElement host is invisible to the
        // user — i.e., no perceptible action, exactly what's wanted.
        //
        // Background color lives in WidgetTheme so the Gmail daily-summary widget
        // renders on exactly the same base — see that type for why dark mode uses
        // #0D0D0F rather than a more moderate near-black.
        contentView
            .containerBackground(for: .widget) {
                WidgetTheme.background(colorScheme)
            }
    }

    @ViewBuilder
    private var contentView: some View {
        if let resolved = entry.resolvedScope, hasAnyAccounts {
            sizedView(for: resolved)
        } else if MailAccountStatusReader.hasConfiguredMailAccounts == false {
            NoMailAccountsView()
        } else {
            EmptyStateView()
        }
    }

    /// `entry.resolvedScope` can be non-nil with zero accounts: the Envelope Index
    /// probe succeeds even when Mail.app has no real account configured (see
    /// `ProviderProbe.hasConfiguredMailAccounts()`), which would otherwise render
    /// indistinguishably from genuine inbox-zero via `sizedView`'s own empty
    /// handling. Gate on the snapshot's actual account list, not just whether
    /// resolution produced a `ResolvedScope`, so that case falls through to the
    /// `NoMailAccountsView` branch above instead.
    private var hasAnyAccounts: Bool {
        !(entry.snapshot?.accounts.isEmpty ?? true)
    }

    @ViewBuilder
    private func sizedView(for resolved: ResolvedScope) -> some View {
        switch family {
        case .systemSmall:
            SmallMailView(resolved: resolved, generatedAt: entry.snapshot?.generatedAt)
        case .systemMedium:
            MediumMailView(resolved: resolved, generatedAt: entry.snapshot?.generatedAt)
        default:
            if #available(macOS 14.0, *), family == .systemExtraLarge {
                ExtraLargeMailView(resolved: resolved, generatedAt: entry.snapshot?.generatedAt)
            } else {
                LargeMailView(resolved: resolved, generatedAt: entry.snapshot?.generatedAt)
            }
        }
    }
}
