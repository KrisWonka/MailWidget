import SwiftUI

/// systemLarge: header (with page controls when the scope has >1 page) + as many
/// recent messages as actually fit in ~345pt of height, most-recent-first.
///
/// The row-count ladder is fine-grained: between "N full-snippet rows" and
/// "(N-1) full-snippet rows" there's a ~60pt jump, which left almost a full row
/// of blank space whenever the true available height fell just short of the
/// taller candidate. Inserting "N rows, but the last 1-2 have no snippet"
/// candidates between those steps closes that gap to about one snippet line
/// (~16pt) instead, so trailing whitespace stays under one row's height. Candidates
/// are listed tallest-first — `ViewThatFits` renders the first one that actually
/// fits — and this list is a true global height ordering (verified against the
/// real per-row metrics via the render harness), not just size-grouped by row
/// count, since a few tail candidates could otherwise be taller than the next
/// full-row-count tier down.
struct LargeMailView: View {
    let resolved: ResolvedScope
    let generatedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MailboxHeaderRow(
                title: resolved.title,
                accountID: resolved.accountID,
                scopeID: resolved.scopeID,
                unreadCount: resolved.unreadCount,
                generatedAt: generatedAt,
                pageInfo: resolved.pageInfo
            )
            Divider()
            if resolved.messages.isEmpty {
                InboxZeroView()
            } else {
                ViewThatFits(in: .vertical) {
                    rows(count: 6, noSnippetTail: 0)
                    rows(count: 6, noSnippetTail: 1)
                    rows(count: 6, noSnippetTail: 2)
                    rows(count: 5, noSnippetTail: 0)
                    rows(count: 5, noSnippetTail: 1)
                    rows(count: 5, noSnippetTail: 2)
                    rows(count: 4, noSnippetTail: 0)
                    rows(count: 4, noSnippetTail: 1)
                    rows(count: 4, noSnippetTail: 2)
                    rows(count: 3, noSnippetTail: 0)
                    rows(count: 3, noSnippetTail: 1)
                    rows(count: 3, noSnippetTail: 2)
                    rows(count: 2, noSnippetTail: 0)
                    rows(count: 1, noSnippetTail: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Renders `count` most recent messages; the last `noSnippetTail` of those
    /// are rendered without a snippet line, trading a little information density
    /// for a shorter overall height (see the type doc for why this exists).
    @ViewBuilder
    private func rows(count: Int, noSnippetTail: Int) -> some View {
        let items = Array(resolved.messages.prefix(count))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.message.id) { index, scoped in
                MessageRow(
                    message: scoped.message,
                    accountID: scoped.accountID,
                    showsSnippet: index < items.count - noSnippetTail
                )
            }
        }
    }
}
