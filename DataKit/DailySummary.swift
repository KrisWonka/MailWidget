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
    static let summaryFilename = "latest.json"

    /// 当前 widget 上那份日报的只读镜像，放在数据目录里给 agent 读（结转用）。
    ///
    /// 为什么不让 agent 直接读 App Group 里那份：App Group 容器受系统保护，codex 的沙箱
    /// 进不去（第二台机器实录：`--ingest` 报「无法访问 App Group」）。也不能读交接目录里的
    /// `latest.json`——那是 agent 自己上一轮**写**的，发布层拒收时（比如零条目守门）它和
    /// widget 上实际显示的不是同一份。
    static let publishedMirrorFilename = "published.json"
    static let maximumItemCount = 6

    /// App Group UserDefaults 里存日报邮箱的键。
    private static let userMailboxKey = "userMailbox"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
    }

    /// 用户的日报邮箱，去个人化之前是编译期常量 `"you@example.com"`——别人克隆
    /// 仓库后永远收不到日报（`DailySummaryValidator` 会拿这个硬编码值挡掉所有载荷）。
    /// 现在是运行时可配置项：读写 App Group `userMailbox` 键，空字符串一律视为"未设置"
    /// （nil），这样调用方不用额外判断"空串"和"没有值"两种形态。
    ///
    /// 正常情况下不需要用户手填——`DailySummaryValidator.validate` 在这个值还是
    /// nil 时会把第一份收到的日报载荷里的 `mailbox` 自动写回这里（首次投递自动认领），
    /// 朋友装上后不用先去设置里配一遍邮箱。
    static var configuredMailbox: String? {
        get {
            guard let value = sharedDefaults?.string(forKey: userMailboxKey),
                  !value.isEmpty else {
                return nil
            }
            return value
        }
        set {
            guard let newValue, !newValue.isEmpty else {
                sharedDefaults?.removeObject(forKey: userMailboxKey)
                return
            }
            sharedDefaults?.set(newValue, forKey: userMailboxKey)
        }
    }

    /// 保留原名供既有调用点（校验、模板渲染、schema 文案……）继续使用，语义变成
    /// "当前配置的邮箱，未配置时是空字符串"。不删掉这个属性——调用点很多，删了要
    /// 逐个改造成 `Optional`，收益不成比例。
    static var expectedMailbox: String {
        configuredMailbox ?? ""
    }

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
    /// Gmail 的 thread ID（没有 thread 时退化为 message ID）。它同时是 `gmailURL`
    /// 片段里的那个 ID。
    let id: String
    let level: DailySummaryLevel
    let title: String
    let detail: String
    let gmailURL: URL

    /// 被总结的那封信的 RFC Message-ID（不含尖括号），可选。
    ///
    /// 有它才能用 `message://` 深链打开 Mail.app 里对应的邮件 —— Gmail 的 thread ID
    /// 与 RFC Message-ID 之间没有可推导的关系，本地也没法靠标题反查（日报标题是
    /// AI 写的中文摘要，跟原始 subject 对不上），所以只能由生成方直接给出。
    ///
    /// 缺省时 widget 回落到 `gmailURL`，因此老的日报载荷照常工作。
    let messageIdHeader: String?

    init(
        id: String,
        level: DailySummaryLevel,
        title: String,
        detail: String,
        gmailURL: URL,
        messageIdHeader: String? = nil
    ) {
        self.id = id
        self.level = level
        self.title = title
        self.detail = detail
        self.gmailURL = gmailURL
        self.messageIdHeader = messageIdHeader
    }
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
        try validateMailbox(summary.mailbox)
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
            try validateMessageIDHeader(item.messageIdHeader, itemID: itemID)
        }
    }

    /// 邮箱校验：**配置了才校验**（不一致仍然拒收），**没配置则放行**并把这份载荷
    /// 的 mailbox 自动写回配置——首次投递自动认领，克隆仓库的人不用先跑去设置里
    /// 填一遍自己的邮箱。空字符串不算"认领"：那既不是一个可用的邮箱，也不该把
    /// "未配置"悄悄伪装成"配置成了空串"。
    private static func validateMailbox(_ mailbox: String) throws {
        if let configured = DailySummaryConstants.configuredMailbox {
            guard mailbox == configured else {
                throw DailySummaryValidationError.unexpectedMailbox(mailbox)
            }
            return
        }
        guard !mailbox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DailySummaryValidationError.unexpectedMailbox(mailbox)
        }
        DailySummaryConstants.configuredMailbox = mailbox
    }

    /// 只在字段存在时校验。要求：去空白后非空、不含尖括号（`MailDeepLink` 自己补
    /// `%3C`/`%3E`，带进来会变成双层）、不含空白字符（会破坏 URL）。
    private static func validateMessageIDHeader(_ value: String?, itemID: String) throws {
        guard let value else { return }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed == value,
            !value.contains("<"),
            !value.contains(">"),
            value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            value.count <= 998
        else {
            throw DailySummaryValidationError.invalidMessageID(itemID)
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
    case invalidMessageID(String)

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
        case let .invalidMessageID(id):
            return "邮件条目 \(id) 的 messageIdHeader 非法：需去掉尖括号、不含空白字符"
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
