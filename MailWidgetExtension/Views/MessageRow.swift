import SwiftUI

/// One message line: an unread dot (or an equal-width blank for read messages,
/// to keep every row's text left-aligned), sender (bold) + subject + relative
/// time, optionally with a secondary-color snippet underneath
/// (systemLarge/systemExtraLarge). Links to the message deep link when a
/// `messageIdHeader` is present; falls back to opening this message's own
/// mailbox (contract 8, item 4) when it isn't, so the row is always tappable
/// instead of silently doing nothing.
struct MessageRow: View {
    let message: MessageSummary
    let accountID: String
    var showsSnippet: Bool = false

    var body: some View {
        if let destination {
            Link(destination: destination) { rowContent }
                .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var destination: URL? {
        if let header = message.messageIdHeader, let url = MailDeepLink.message(for: header) {
            return url
        }
        return MailDeepLink.mailbox(accountID: accountID)
    }

    private var rowContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            unreadDot
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.sender)
                        .font(WidgetTheme.rowTitleFont)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(message.date, style: .relative)
                        .font(WidgetTheme.metaFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(message.subject)
                    .font(WidgetTheme.rowBodyFont)
                    .lineLimit(1)
                    .foregroundStyle(message.isRead ? .secondary : .primary)
                if showsSnippet {
                    Text(message.snippet)
                        .font(WidgetTheme.metaFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Same-Mail-app-style solid dot for unread messages; read messages keep an
    /// equal-width transparent placeholder so every row's text still lines up.
    private var unreadDot: some View {
        Circle()
            .fill(message.isRead ? Color.clear : Color.accentColor)
            .frame(width: 7, height: 7)
    }
}
