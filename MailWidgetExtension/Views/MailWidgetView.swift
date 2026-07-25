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
        // Background color: dark mode uses #0D0D0F rather than a more moderate
        // near-black — macOS 26+ layers an automatic specular/glass highlight on
        // top of whatever `.containerBackground` fills with (no first-party way
        // to opt out of it), which lightens the rendered result. Going darker
        // than the "true" target color is what keeps the *composited* appearance
        // reading as near-black once that highlight is layered on top.
        contentView
            .containerBackground(for: .widget) {
                colorScheme == .dark
                    ? Color(red: 0x0D / 255, green: 0x0D / 255, blue: 0x0F / 255)
                    : Color.white
            }
    }

    @ViewBuilder
    private var contentView: some View {
        if let resolved = entry.resolvedScope {
            sizedView(for: resolved)
        } else {
            EmptyStateView()
        }
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
