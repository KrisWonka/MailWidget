// DailySummary.swift
// DataKit — Gmail 日报的数据模型与校验。由外部 agent 生成 JSON，经 `--ingest` 进入 App Group。
// 从原 GmailDailyWidget/Shared/DailySummary.swift 搬入；校验语义逐条保持不变，
// 仅把 `WidgetConstants` 改名为 `DailySummaryConstants` 以避免与 MailWidget 侧的
// `SharedConstants` 混淆。schemaVersion 保持 1，不做任何 schema 变更。

import Foundation

enum DailySummaryConstants {
    /// Widget kind。沿用原值：它是 extension 内部标识符，换掉没有收益，
    /// 只会让已有的 reload 调用点全部要跟着改。
    static let kind = "com.kris.GmailDailyWidget.daily"
    static let expectedMailbox = "krisxia@umich.edu"
    static let summaryFilename = "latest.json"
    static let maximumItemCount = 6

    /// agent 与 App 的交接目录。刻意保留原路径：Codex automation 的 prompt 里
    /// 这个路径出现多次，不动它就少改一处、少一处出错机会。
    static var dataDirectoryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/GmailDailyWidget", isDirectory: true)
    }
}

enum DailySummaryLevel: String, Codable, CaseIterable, Sendable {
    case immediate
    case today
    case week
    case optional
    case info
}

struct DailySummaryItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let level: DailySummaryLevel
    let title: String
    let detail: String
    let gmailURL: URL
}

struct DailySummary: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let mailbox: String
    let generatedAt: String
    let headline: String
    let items: [DailySummaryItem]

    var generatedDate: Date? {
        ISO8601DateParser.date(from: generatedAt)
    }
}

enum DailySummaryCodec {
    static func decode(_ data: Data) throws -> DailySummary {
        let summary = try JSONDecoder().decode(DailySummary.self, from: data)
        try DailySummaryValidator.validate(summary)
        return summary
    }

    static func encode(_ summary: DailySummary) throws -> Data {
        try DailySummaryValidator.validate(summary)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(summary)
    }
}

enum DailySummaryValidator {
    static func validate(_ summary: DailySummary) throws {
        guard summary.schemaVersion == 1 else {
            throw DailySummaryValidationError.unsupportedSchemaVersion(summary.schemaVersion)
        }
        guard summary.mailbox == DailySummaryConstants.expectedMailbox else {
            throw DailySummaryValidationError.unexpectedMailbox(summary.mailbox)
        }
        guard ISO8601DateParser.date(from: summary.generatedAt) != nil else {
            throw DailySummaryValidationError.invalidGeneratedAt(summary.generatedAt)
        }
        guard summary.items.count <= DailySummaryConstants.maximumItemCount else {
            throw DailySummaryValidationError.tooManyItems(summary.items.count)
        }

        var itemIDs = Set<String>()
        for item in summary.items {
            let itemID = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !itemID.isEmpty else {
                throw DailySummaryValidationError.emptyItemID
            }
            guard itemIDs.insert(itemID).inserted else {
                throw DailySummaryValidationError.duplicateItemID(itemID)
            }
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DailySummaryValidationError.emptyTitle(itemID)
            }
            try validateGmailURL(item.gmailURL, itemID: itemID)
        }
    }

    /// 链接必须精确指向"当前邮箱里同 ID 的那封信"。任何一处不符即拒绝——
    /// 这是防止 widget 上出现可点击但指向别处的链接。
    private static func validateGmailURL(_ url: URL, itemID: String) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DailySummaryValidationError.invalidGmailURL(itemID)
        }

        let authUserItems = (components.queryItems ?? []).filter { $0.name == "authuser" }
        guard
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == "mail.google.com",
            components.port == nil,
            components.user == nil,
            components.password == nil,
            components.path == "/mail/u/0/",
            components.queryItems?.count == 1,
            authUserItems.count == 1,
            authUserItems[0].value == DailySummaryConstants.expectedMailbox,
            components.fragment == "all/\(itemID)"
        else {
            throw DailySummaryValidationError.invalidGmailURL(itemID)
        }
    }
}

enum DailySummaryValidationError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case unexpectedMailbox(String)
    case invalidGeneratedAt(String)
    case tooManyItems(Int)
    case emptyItemID
    case duplicateItemID(String)
    case emptyTitle(String)
    case invalidGmailURL(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "不支持 schemaVersion=\(version)，当前只接受 1"
        case let .unexpectedMailbox(mailbox):
            return "邮箱不匹配：\(mailbox)"
        case let .invalidGeneratedAt(value):
            return "generatedAt 不是有效的 ISO 8601 时间：\(value)"
        case let .tooManyItems(count):
            return "邮件条目过多：\(count)，最多接受 \(DailySummaryConstants.maximumItemCount) 条"
        case .emptyItemID:
            return "邮件条目的 id 不能为空"
        case let .duplicateItemID(id):
            return "邮件条目的 id 重复：\(id)"
        case let .emptyTitle(id):
            return "邮件条目 \(id) 的标题不能为空"
        case let .invalidGmailURL(id):
            return "邮件条目 \(id) 的链接必须指向当前邮箱中同 ID 的 Gmail 邮件"
        }
    }
}

private enum ISO8601DateParser {
    static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
