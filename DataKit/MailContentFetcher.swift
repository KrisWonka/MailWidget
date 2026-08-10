// MailContentFetcher.swift
// DataKit — 契约 12：为邮件总结批量抓取邮件正文。跟 AppleScriptProvider 同一套手法——
// 一次 NSAppleScript.executeAndReturnError 调用内部循环账户/邮件，ASCII 分隔符
// （GS=账户块之间、RS=同账户内消息记录之间、US=单条记录内字段之间）拼成一个大字符串
// 一次性返回，避免多次跨进程 Apple Event 调用。
//
// 与 AppleScriptProvider 的差异：
// - 每账户最多取 inbox 前 20 封（总结场景比 widget 展示需要更多素材），而不是 10 封；
// - 额外在 AppleScript 里截断正文到前 2000 字符（`content of msg` 全文可能很长，
//   截断发生在脚本内部，不把全文经 Apple Event 拉回主进程）；
// - 不产出 MessageSummary/AccountSummary（widget 快照模型），只产出 FetchedMail——
//   总结链路不需要账户分组、mailbox role、flagged 等字段。
// - Message-ID 头的完整抽取（`all headers of msg` 正则兜底 `message id` 属性丢
//   @domain 的坑）、sender 字符串拆分，直接复用 AppleScriptProvider 已经踩过坑、
//   已经单测过的 internal 静态函数（`extractMessageIdHeader` / `splitSender` /
//   `stripAngleBrackets`），不重新发明一遍。
//
// 仅宿主可用：跟 AppleScriptProvider 同样的检测（extension 的 Info.plist 一定有
// NSExtension 这个 key，宿主 app 没有），widget extension 环境里直接 throw。

import Foundation
#if canImport(AppKit)
import AppKit
#endif

struct FetchedMail {
    let messageIdHeader: String?
    let sender: String
    let senderEmail: String
    let subject: String
    let date: Date
    let isRead: Bool
    let bodyPrefix: String
}

enum MailContentFetcher {

    enum FetchError: Error, CustomStringConvertible {
        case unavailableInExtension
        case appleScriptUnsupported
        case scriptError(String)

        var description: String {
            switch self {
            case .unavailableInExtension:
                return "MailContentFetcher is host-app only; widget extension cannot drive Mail.app"
            case .appleScriptUnsupported:
                return "NSAppleScript is unavailable in this process"
            case .scriptError(let message):
                return "AppleScript error: \(message)"
            }
        }
    }

    private static var isRunningInAppExtension: Bool {
        Bundle.main.infoDictionary?["NSExtension"] != nil
    }

    private static let accountSeparator = "\u{1D}" // GS：账户块之间
    private static let recordSeparator = "\u{1E}"  // RS：账户块内消息记录之间
    private static let fieldSeparator = "\u{1F}"   // US：单条消息记录内字段之间

    /// 总结场景需要比 widget 展示（10 封）更多素材，且总量还会被 MailSummarizer
    /// 的"unread 优先、按日期倒序，≤20 封"再筛一轮，所以每账户先取够 20 封。
    static let messagesPerAccount = 20
    /// 正文截断长度：留给 Claude 判断需不需要行动，2000 字符足够覆盖大多数邮件的
    /// 关键信息，同时把 prompt 总长度控制在可控范围（见 MailSummarizer 的长度断言）。
    static let bodyPrefixLength = 2000

    /// accountNames == nil → 每个账户；否则只取名字在列表里的账户（用于 `account:<id>`
    /// scope，调用方已经从 SnapshotStore 里把账户 ID 解析成账户名）。
    static func fetch(accountNames: [String]?) throws -> [FetchedMail] {
        guard !isRunningInAppExtension else {
            throw FetchError.unavailableInExtension
        }
        #if canImport(AppKit)
        guard let script = NSAppleScript(source: scriptSource(accountNames: accountNames)) else {
            throw FetchError.appleScriptUnsupported
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "\(errorInfo)"
            throw FetchError.scriptError(message)
        }
        let raw = result.stringValue ?? ""
        return parseAccounts(raw)
        #else
        throw FetchError.appleScriptUnsupported
        #endif
    }

    // MARK: - AppleScript source

    /// AppleScript 字符串字面量：转义反斜杠和双引号，供拼进脚本源码。
    static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// AppleScript list 字面量，如 `{"Work", "Personal"}`。
    static func appleScriptListLiteral(_ values: [String]) -> String {
        "{" + values.map(appleScriptStringLiteral).joined(separator: ", ") + "}"
    }

    /// 账户过滤 + 每账户 inbox 前 N 封的批量抓取脚本。`hasFilter`/`filterNames` 两个
    /// AppleScript 变量把 Swift 侧的 `accountNames` 过滤条件带进脚本；账户名本身是
    /// 运行时从 `name of acct` 取到的值，字段拼接用 `&` 做运行时字符串连接，不涉及
    /// 源码层面的转义问题（只有 filterNames 这个字面量本身需要转义，因为它是拼进
    /// 脚本源码文本的）。
    static func scriptSource(accountNames: [String]?) -> String {
        let hasFilter = accountNames != nil
        let filterLiteral = appleScriptListLiteral(accountNames ?? [])
        return """
        on run
            set GS to (ASCII character 29)
            set RS to (ASCII character 30)
            set US to (ASCII character 31)
            set hasFilter to \(hasFilter ? "true" : "false")
            set filterNames to \(filterLiteral)
            set outputChunks to {}
            tell application "Mail"
                set theAccounts to every account
                repeat with acct in theAccounts
                    try
                        set acctName to name of acct
                        set includeAccount to true
                        if hasFilter then
                            if not (filterNames contains acctName) then set includeAccount to false
                        end if
                        if includeAccount then
                            set theInbox to mailbox "INBOX" of acct
                            set theMessages to messages of theInbox
                            set msgCount to count of theMessages
                            set fetchCount to msgCount
                            if fetchCount > \(messagesPerAccount) then set fetchCount to \(messagesPerAccount)
                            set msgChunks to {}
                            if fetchCount > 0 then
                                repeat with i from 1 to fetchCount
                                    set msg to item i of theMessages
                                    set msgIdHeader to ""
                                    try
                                        set msgIdHeader to message id of msg
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
                                    set bodyText to ""
                                    try
                                        set c to content of msg
                                        if (count of c) > \(bodyPrefixLength) then
                                            set bodyText to text 1 thru \(bodyPrefixLength) of c
                                        else
                                            set bodyText to c
                                        end if
                                    end try
                                    set headerText to ""
                                    try
                                        set headerText to (all headers of msg) as string
                                    end try
                                    set msgField to msgIdHeader & US & senderRaw & US & subj & US & isRead & US & y & US & mo & US & d & US & hh & US & mm & US & ss & US & bodyText & US & headerText
                                    set end of msgChunks to msgField
                                end repeat
                            end if
                            set msgsJoined to ""
                            repeat with i from 1 to (count of msgChunks)
                                if i > 1 then set msgsJoined to msgsJoined & RS
                                set msgsJoined to msgsJoined & (item i of msgChunks)
                            end repeat
                            set acctChunk to acctName
                            if (length of msgsJoined) > 0 then
                                set acctChunk to acctName & RS & msgsJoined
                            end if
                            set end of outputChunks to acctChunk
                        end if
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
    }

    // MARK: - Parsing
    //
    // 纯解析函数（不碰 AppleScript/NSWorkspace），internal 方便直接喂合成文本单测，
    // 不用真的执行 AppleScript（会弹自动化权限框、拉起 Mail.app）。

    static func parseAccounts(_ raw: String) -> [FetchedMail] {
        guard !raw.isEmpty else { return [] }
        let accountChunks = raw.components(separatedBy: accountSeparator)
        var result: [FetchedMail] = []
        for chunk in accountChunks {
            guard !chunk.isEmpty else { continue }
            let records = chunk.components(separatedBy: recordSeparator)
            // records[0] 是账户名（头记录），本函数不对外暴露账户分组，只解析消息记录。
            let messageRecords = records.dropFirst()
            for record in messageRecords {
                if let mail = parseMessage(record) {
                    result.append(mail)
                }
            }
        }
        return result
    }

    /// 字段顺序需与 `scriptSource` 里 `msgField` 的拼接顺序一致：
    /// 0 msgIdHeader（`message id` 属性，已知会丢 @domain，仅当兜底）
    /// 1 senderRaw  2 subject  3 isRead("0"/"1")
    /// 4 year 5 month 6 day 7 hour 8 minute 9 second
    /// 10 bodyText（已在 AppleScript 内截断到 bodyPrefixLength）
    /// 11 headerText（`all headers of msg`，用于抠出完整 Message-Id）
    static func parseMessage(_ record: String) -> FetchedMail? {
        let fields = record.components(separatedBy: fieldSeparator)
        guard fields.count >= 11 else { return nil }
        let legacyMessageIdProperty = fields[0]
        let senderRaw = fields[1]
        let subject = fields[2]
        let isRead = fields[3] == "1"
        let year = Int(fields[4])
        let month = Int(fields[5])
        let day = Int(fields[6])
        let hour = Int(fields[7])
        let minute = Int(fields[8])
        let second = fields.count > 9 ? Int(fields[9]) : 0
        let rawBody = fields.count > 10 ? fields[10] : ""
        let rawHeaderText = fields.count > 11 ? fields[11] : ""

        // 复用 AppleScriptProvider 已经踩过坑、已经单测过的抽取逻辑：`all headers`
        // 正则优先，`message id` 属性仅当兜底（那个属性值会丢 @domain）。
        let messageIdHeader = AppleScriptProvider.extractMessageIdHeader(
            rawHeaderText: rawHeaderText,
            legacyProperty: legacyMessageIdProperty
        )
        let (senderName, senderEmail) = AppleScriptProvider.splitSender(senderRaw)

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

        return FetchedMail(
            messageIdHeader: messageIdHeader,
            sender: senderName,
            senderEmail: senderEmail,
            subject: subject,
            date: date,
            isRead: isRead,
            bodyPrefix: rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
