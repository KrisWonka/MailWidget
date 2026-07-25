import SwiftUI

/// systemExtraLarge: same header as Large (page controls included), but messages
/// split into two columns so the extra width is put to use instead of just
/// stretching the single-column Large layout.
///
/// Same fine-grained `ViewThatFits` ladder as Large (see that file's doc for why),
/// applied per-column-pair so both columns always pick the same row count/style —
/// evaluated once for the whole two-column layout, not independently per column.
struct ExtraLargeMailView: View {
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
                    columns(perColumn: 6, noSnippetTail: 0)
                    columns(perColumn: 6, noSnippetTail: 1)
                    columns(perColumn: 6, noSnippetTail: 2)
                    columns(perColumn: 5, noSnippetTail: 0)
                    columns(perColumn: 5, noSnippetTail: 1)
                    columns(perColumn: 5, noSnippetTail: 2)
                    columns(perColumn: 4, noSnippetTail: 0)
                    columns(perColumn: 4, noSnippetTail: 1)
                    columns(perColumn: 4, noSnippetTail: 2)
                    columns(perColumn: 3, noSnippetTail: 0)
                    columns(perColumn: 3, noSnippetTail: 1)
                    columns(perColumn: 3, noSnippetTail: 2)
                    columns(perColumn: 2, noSnippetTail: 0)
                    columns(perColumn: 1, noSnippetTail: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func columns(perColumn: Int, noSnippetTail: Int) -> some View {
        let messages = Array(resolved.messages.prefix(perColumn * 2))
        let half = (messages.count + 1) / 2
        let left = Array(messages.prefix(half))
        let right = Array(messages.dropFirst(half))

        HStack(alignment: .top, spacing: 20) {
            column(left, noSnippetTail: noSnippetTail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !right.isEmpty {
                Divider()
                column(right, noSnippetTail: noSnippetTail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Same "last `noSnippetTail` rows have no snippet" trick as Large, applied
    /// within one column.
    @ViewBuilder
    private func column(_ items: [ScopedMessage], noSnippetTail: Int) -> some View {
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
