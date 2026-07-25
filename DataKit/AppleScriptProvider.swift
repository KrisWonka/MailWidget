// AppleScriptProvider.swift
// DataKit — 兜底数据源：`tell application "Mail"` 取每个账户 inbox 的未读数 + 最近 ≤10 封。
// 仅宿主 app 能用（需要"自动化"权限去控制 Mail.app）；在 widget extension 里直接 throw。
// 性能：整段抓取只发一次 NSAppleScript.executeAndReturnError 调用（脚本内部循环账户/邮件），
// 不会每个账户或每封邮件单独调用一次。
//
// P0 修复记录（返工，实锤证据见交付报告）：Mail.app 的 AppleScript `message id` 属性
// 实测会把 Message-ID 里 @ 及其后的域名整段吞掉（`<1234@example.com>` 只拿到 `1234`），
// 导致 deep link 用的 messageIdHeader 全部缺域名、全部打不开。修法：不再信任那个属性，
// 改成从 `all headers of msg`（Mail 给的原始头块，逐字包含完整 Message-Id 行）里用正则把
// 完整 ID 抠出来；`message id` 属性值仅在正则失败时才当兜底用（也就是明知有缺陷的兜底）。

import Foundation
#if canImport(AppKit)
import AppKit
#endif

final class AppleScriptProvider: MailDataProvider {

    enum ProviderError: Error, CustomStringConvertible {
        case unavailableInExtension
        case appleScriptUnsupported
        case scriptError(String)

        var description: String {
            switch self {
            case .unavailableInExtension:
                return "AppleScriptProvider is host-app only; widget extension cannot drive Mail.app"
            case .appleScriptUnsupported:
                return "NSAppleScript is unavailable in this process"
            case .scriptError(let message):
                return "AppleScript error: \(message)"
            }
        }
    }

    /// widget extension 的 Info.plist 里一定有 NSExtension 这个 key；宿主 app 没有。
    private static var isRunningInAppExtension: Bool {
        Bundle.main.infoDictionary?["NSExtension"] != nil
    }

    private static let recordSeparator = "\u{1E}" // RS：账户/消息记录之间
    private static let fieldSeparator = "\u{1F}"  // US：单条记录内的字段之间
    private static let accountSeparator = "\u{1D}" // GS：账户块之间
    /// 有意保持 10，没有跟 EnvelopeIndexProvider 的 50 一起提（2026-07-23）：这条兜底
    /// 通道要驱动 Mail.app 逐封读 `content of msg`（正文）才能拿摘要，条数越多越慢、
    /// 还会拉起/占用 Mail.app；EnvelopeIndexProvider 只是本地 SQLite 查询，条数对它
    /// 几乎不影响耗时，两边取信成本不是一个量级，没有理由跟着涨。
    private static let messagesPerMailbox = 10

    func fetchSnapshot() throws -> MailSnapshot {
        guard !Self.isRunningInAppExtension else {
            throw ProviderError.unavailableInExtension
        }
        #if canImport(AppKit)
        guard let script = NSAppleScript(source: Self.scriptSource) else {
            throw ProviderError.appleScriptUnsupported
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "\(errorInfo)"
            throw ProviderError.scriptError(message)
        }
        let raw = result.stringValue ?? ""
        let accounts = Self.parseAccounts(raw)
        return MailSnapshot(generatedAt: Date(), providerKind: "appleScript", accounts: accounts)
        #else
        throw ProviderError.appleScriptUnsupported
        #endif
    }

    // MARK: - AppleScript source

    /// 一次性批量抓取：遍历 Mail 里的每个账户，读 INBOX 未读数 + 最近 ≤10 封邮件的字段，
    /// 用 ASCII 分隔符拼成一个大字符串一次性返回，避免多次跨进程 Apple Event 调用。
    private static let scriptSource = """
    on run
        set GS to (ASCII character 29)
        set RS to (ASCII character 30)
        set US to (ASCII character 31)
        set outputChunks to {}
        tell application "Mail"
            set theAccounts to every account
            repeat with acct in theAccounts
                try
                    set acctName to name of acct
                    set acctEmail to ""
                    try
                        set addrs to email addresses of acct
                        if (count of addrs) > 0 then set acctEmail to item 1 of addrs
                    end try
                    set theInbox to mailbox "INBOX" of acct
                    set unreadCnt to unread count of theInbox
                    set theMessages to messages of theInbox
                    set msgCount to count of theMessages
                    set fetchCount to msgCount
                    if fetchCount > 10 then set fetchCount to 10
                    set msgChunks to {}
                    if fetchCount > 0 then
                        repeat with i from 1 to fetchCount
                            set msg to item i of theMessages
                            set msgIdHeader to ""
                            try
                                set msgIdHeader to message id of msg
                            end try
                            set internalId to ""
                            try
                                set internalId to (id of msg) as string
                            end try
                            set senderRaw to ""
                            try
                                set senderRaw to sender of msg
                            end try
                            set subj to ""
                            try
                                set subj to subject of msg
                            end try
                            set isRead to "0"
                            try
                                if read status of msg then set isRead to "1"
                            end try
                            set isFlag to "0"
                            try
                                if flagged status of msg then set isFlag to "1"
                            end try
                            set y to ""
                            set mo to ""
                            set d to ""
                            set hh to ""
                            set mm to ""
                            set ss to ""
                            try
                                set dr to date received of msg
                                set y to (year of dr) as string
                                set mo to ((month of dr) as integer) as string
                                set d to (day of dr) as string
                                set hh to (hours of dr) as string
                                set mm to (minutes of dr) as string
                                set ss to (seconds of dr) as string
                            end try
                            set snippetText to ""
                            try
                                set c to content of msg
                                if (count of c) > 200 then
                                    set snippetText to text 1 thru 200 of c
                                else
                                    set snippetText to c
                                end if
                            end try
                            set headerText to ""
                            try
                                set headerText to (all headers of msg) as string
                            end try
                            set msgField to msgIdHeader & US & internalId & US & senderRaw & US & subj & US & isRead & US & isFlag & US & y & US & mo & US & d & US & hh & US & mm & US & ss & US & snippetText & US & headerText
                            set end of msgChunks to msgField
                        end repeat
                    end if
                    set msgsJoined to ""
                    repeat with i from 1 to (count of msgChunks)
                        if i > 1 then set msgsJoined to msgsJoined & RS
                        set msgsJoined to msgsJoined & (item i of msgChunks)
                    end repeat
                    set headerField to acctName & US & acctEmail & US & (unreadCnt as string)
                    set acctChunk to headerField
                    if (length of msgsJoined) > 0 then
                        set acctChunk to headerField & RS & msgsJoined
                    end if
                    set end of outputChunks to acctChunk
                end try
            end repeat
        end tell
        set finalOutput to ""
        repeat with i from 1 to (count of outputChunks)
            if i > 1 then set finalOutput to finalOutput & GS
            set finalOutput to finalOutput & (item i of outputChunks)
        end repeat
        return finalOutput
    end run
    """

    // MARK: - Parsing
    //
    // 下面这批纯解析函数（不碰 AppleScript/NSWorkspace）放宽到 internal，方便 test-dev
    // 直接喂合成文本单测，不用真的执行 AppleScript（会弹自动化权限框）。

    static func parseAccounts(_ raw: String) -> [AccountSummary] {
        guard !raw.isEmpty else { return [] }
        let accountChunks = raw.components(separatedBy: accountSeparator)
        var accounts: [AccountSummary] = []
        for (index, chunk) in accountChunks.enumerated() {
            guard !chunk.isEmpty else { continue }
            let records = chunk.components(separatedBy: recordSeparator)
            guard let headerRecord = records.first else { continue }
            let headerFields = headerRecord.components(separatedBy: fieldSeparator)
            guard headerFields.count >= 3 else { continue }
            let name = headerFields[0]
            let email = headerFields[1]
            let unreadCount = Int(headerFields[2]) ?? 0

            let messageRecords = records.dropFirst()
            let messages = messageRecords.compactMap { parseMessage($0) }
                .sorted { $0.date > $1.date }
                .prefix(messagesPerMailbox)

            let slug = slugify(name.isEmpty ? "account-\(index + 1)" : name)
            let account = AccountSummary(
                id: "applescript:\(slug)",
                name: name.isEmpty ? "Account \(index + 1)" : name,
                email: email,
                mailboxes: [
                    MailboxSummary(
                        id: "applescript:\(slug):inbox",
                        name: "Inbox",
                        role: "inbox",
                        unreadCount: unreadCount,
                        messages: Array(messages)
                    )
                ]
            )
            accounts.append(account)
        }
        return accounts
    }

    static func parseMessage(_ record: String) -> MessageSummary? {
        let fields = record.components(separatedBy: fieldSeparator)
        guard fields.count >= 11 else { return nil }
        let legacyMessageIdProperty = fields[0]
        let internalId = fields[1]
        let senderRaw = fields[2]
        let subject = fields[3]
        let isRead = fields[4] == "1"
        let isFlagged = fields[5] == "1"
        let year = Int(fields[6])
        let month = Int(fields[7])
        let day = Int(fields[8])
        let hour = Int(fields[9])
        let minute = Int(fields[10])
        let second = fields.count > 11 ? Int(fields[11]) : 0
        let rawSnippet = fields.count > 12 ? fields[12] : ""
        let rawHeaderText = fields.count > 13 ? fields[13] : ""

        let messageIdHeader = extractMessageIdHeader(rawHeaderText: rawHeaderText, legacyProperty: legacyMessageIdProperty)
        let id = messageIdHeader ?? (internalId.isEmpty ? UUID().uuidString : internalId)

        let (senderName, senderEmail) = splitSender(senderRaw)

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second ?? 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)

        return MessageSummary(
            id: id,
            messageIdHeader: messageIdHeader,
            sender: senderName,
            senderEmail: senderEmail,
            subject: subject,
            snippet: makeSnippet(rawSnippet),
            date: date,
            isRead: isRead,
            isFlagged: isFlagged
        )
    }

    /// Mail 的 `sender` 属性一般是 "Display Name <email@x.com>" 这种格式；也可能只有邮箱。
    static func splitSender(_ raw: String) -> (name: String, email: String) {
        guard let openIdx = raw.firstIndex(of: "<"), let closeIdx = raw.firstIndex(of: ">"), openIdx < closeIdx else {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            return (trimmed, trimmed.contains("@") ? trimmed : "")
        }
        let email = String(raw[raw.index(after: openIdx)..<closeIdx])
        let namePart = String(raw[raw.startIndex..<openIdx]).trimmingCharacters(in: .whitespaces)
        return (namePart.isEmpty ? email : namePart, email)
    }

    /// Message-ID 头正则：`Message-Id:` 后面第一个 `<...>` 尖括号内的内容（含 @domain）。
    /// `.anchorsMatchLines` 让 `^` 匹配每一行行首，兼容 \n / \r\n 换行的原始头块。
    private static let messageIdHeaderRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^Message-Id:\s*<([^>\r\n]+)>"#,
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    /// 从 `all headers of msg` 原始头块里精确抠出 Message-Id（含域名）。抠不到返回 nil。
    static func messageIdFromRawHeaders(_ rawHeaderText: String) -> String? {
        guard !rawHeaderText.isEmpty, let regex = messageIdHeaderRegex else { return nil }
        let range = NSRange(rawHeaderText.startIndex..<rawHeaderText.endIndex, in: rawHeaderText)
        guard let match = regex.firstMatch(in: rawHeaderText, options: [], range: range),
              let captureRange = Range(match.range(at: 1), in: rawHeaderText) else {
            return nil
        }
        let captured = String(rawHeaderText[captureRange])
        return captured.isEmpty ? nil : captured
    }

    /// 优先从原始头块抠完整 Message-Id；抠不到（比如 all headers 也拿不到）才退回
    /// Mail 的 `message id` 属性值（已知会丢 @domain，仅当最后手段）。两边都会再走一遍
    /// stripAngleBrackets 保证契约要求的"不含尖括号"。
    static func extractMessageIdHeader(rawHeaderText: String, legacyProperty: String) -> String? {
        if let fromHeaders = messageIdFromRawHeaders(rawHeaderText) {
            return stripAngleBrackets(fromHeaders)
        }
        return stripAngleBrackets(legacyProperty)
    }

    static func stripAngleBrackets(_ value: String) -> String? {
        var result = value
        guard !result.isEmpty else { return nil }
        if result.hasPrefix("<") { result.removeFirst() }
        if result.hasSuffix(">") { result.removeLast() }
        return result.isEmpty ? nil : result
    }

    static func makeSnippet(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 120 else { return collapsed }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: 117)
        return String(collapsed[..<cutoff]) + "…"
    }

    static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = CharacterSet.alphanumerics
        let mapped = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped)
    }
}
