import SwiftUI

/// systemMedium: header (mailbox name + unread count) + as many recent messages
/// (sender bold, subject, relative time; no snippet at this density) as fit in
/// ~158pt of height.
///
/// P0 fix: same overflow bug as Large — a fixed 3-row count turned out to
/// already exceed Medium's height budget too. `ViewThatFits` picks the largest
/// row count (3, 2, or 1) that actually fits instead of guessing.
struct MediumMailView: View {
    let resolved: ResolvedScope
    let generatedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetTheme.sectionSpacingMedium) {
            MailboxHeaderRow(title: resolved.title, accountID: resolved.accountID, scopeID: resolved.scopeID, unreadCount: resolved.unreadCount, generatedAt: generatedAt)
            Divider()
            if resolved.messages.isEmpty {
                InboxZeroView()
            } else {
                ViewThatFits(in: .vertical) {
                    rows(count: 3)
                    rows(count: 2)
                    rows(count: 1)
                }
            }
        }
        .padding(WidgetTheme.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func rows(count: Int) -> some View {
        VStack(alignment: .leading, spacing: WidgetTheme.rowSpacing) {
            ForEach(resolved.messages.prefix(count), id: \.message.id) { scoped in
                MessageRow(message: scoped.message, accountID: scoped.accountID)
            }
        }
    }
}
