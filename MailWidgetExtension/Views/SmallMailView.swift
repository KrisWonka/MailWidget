import SwiftUI

/// systemSmall: mailbox name (tappable — contract 8, item 3) + large unread count
/// + the single most recent sender/subject. No timestamp, no snippet — deliberately
/// the lowest density tier.
struct SmallMailView: View {
    let resolved: ResolvedScope
    let generatedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetTheme.sectionSpacingSmall) {
            HStack {
                titleView
                Spacer()
                if isStale {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text("\(resolved.unreadCount)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(resolved.unreadCount > 0 ? Color.accentColor : Color.secondary)

            Spacer(minLength: 0)

            if let latest = resolved.messages.first {
                latestMessagePreview(latest)
            } else {
                Text("No unread mail")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(WidgetTheme.paddingSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var titleView: some View {
        let text = Text(resolved.title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        if let url = MailDeepLink.mailbox(accountID: resolved.accountID) {
            Link(destination: url) { text }
                .buttonStyle(.plain)
        } else {
            text
        }
    }

    @ViewBuilder
    private func latestMessagePreview(_ scoped: ScopedMessage) -> some View {
        let preview = VStack(alignment: .leading, spacing: 1) {
            Text(scoped.message.sender)
                .font(.caption2.bold())
                .lineLimit(1)
            Text(scoped.message.subject)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        let destination = scoped.message.messageIdHeader.flatMap(MailDeepLink.message(for:))
            ?? MailDeepLink.mailbox(accountID: scoped.accountID)

        if let destination {
            Link(destination: destination) { preview }
                .buttonStyle(.plain)
        } else {
            preview
        }
    }

    private var isStale: Bool {
        guard let generatedAt else { return false }
        return Date().timeIntervalSince(generatedAt) > 10 * 60
    }
}
