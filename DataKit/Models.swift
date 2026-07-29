// Models.swift
// DataKit — 契约 1：快照数据模型。Codable，JSON 存于 App Group 容器 snapshot.json。
// 编译进宿主 app 和 widget extension 两个 target；类型均为 internal（默认访问级别）。

import Foundation

/// App Group / 共享设置相关常量（契约 5）。
enum SharedConstants {
    /// App Group ID，宿主 app 与 widget extension 共用的容器标识符。
    static let appGroupIdentifier = "LR8V7939D4.com.kris.mailwidget"

    /// UserDefaults（suite = App Group）里的刷新间隔键，Double，单位分钟。
    static let refreshIntervalMinutesKey = "refreshIntervalMinutes"

    /// 刷新间隔默认值（分钟）。
    static let defaultRefreshIntervalMinutes: Double = 2
}

/// scope 标识字符串的唯一权威来源。`SnapshotStore.applyLocalMarkAllRead(scopeID:)`、
/// 宿主 app `App.swift` 里"scope 字符串 → MarkAllReadTarget"的解析、以及 widget
/// extension 的 `MailScopeEntity`（该类型自己再 `= MailScope.xxx` 重新导出一遍，
/// 因为它活在 extension target，看不到 App.swift 那份）三处必须永远用同一套值。
///
/// 阶段三 review 批 1 High #1 修复：在这之前 "all" / "account:" 是分别硬编码在至少
/// 三个文件里的字面量，没有单一权威——这正是 App.swift 那个"无法识别的 scope 走进
/// nil 分支、nil 又被解释成『全部账户』"的 fail-open bug 能悄悄发生的土壤。
enum MailScope {
    static let all = "all"
    static let vip = "vip"
    static let flagged = "flagged"
    static let accountPrefix = "account:"
}

/// 一次快照 = 某个时间点抓取到的全部账户/邮箱/邮件状态。
struct MailSnapshot: Codable {
    /// 抓取时间；frontend 据此渲染"数据过期"态（> 10 min 视为过期）。
    let generatedAt: Date
    /// 产出该快照的数据源，"envelopeIndex" | "appleScript"，供调试显示。
    let providerKind: String
    let accounts: [AccountSummary]
}

struct AccountSummary: Codable {
    /// 稳定标识：Envelope 通道下是账户 UUID；AppleScript 通道下是合成 slug。
    let id: String
    let name: String
    let email: String
    let mailboxes: [MailboxSummary]
}

struct MailboxSummary: Codable {
    let id: String
    let name: String
    /// "inbox" | "vip" | "flagged" | "other"
    let role: String
    let unreadCount: Int
    /// 按时间倒序；Envelope 通道最多 50 封（2026-07-23 起，供 widget 翻页），
    /// AppleScript 兜底通道性能限制仍是 10 封。
    let messages: [MessageSummary]
}

struct MessageSummary: Codable {
    /// 稳定标识：优先 RFC Message-ID，缺失时用 Envelope ROWID 字符串。
    let id: String
    /// RFC Message-ID（不含尖括号），deep link 用；可能为 nil。
    let messageIdHeader: String?
    let sender: String
    let senderEmail: String
    let subject: String
    /// 正文摘要，≤120 字符。
    let snippet: String
    let date: Date
    let isRead: Bool
    let isFlagged: Bool
}
