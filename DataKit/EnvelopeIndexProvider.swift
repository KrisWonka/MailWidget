// EnvelopeIndexProvider.swift
// DataKit — 主数据源：只读查询 ~/Library/Mail/V*/MailData/Envelope Index（SQLite，WAL 模式）。
// 用系统 SQLite3 C API，sqlite3_open_v2 + SQLITE_OPEN_READONLY + URI ?mode=ro。
// V 目录动态探测（取数字最大的 V*）。启动时校验所需表/列存在，任何不匹配即 throw，交给选择器降级。
//
// 关键实测发现（本机 macOS 27.0 / Mail V10，与 spike 简报有出入，详见交付报告）：
// 1. message_global_data 的关联键不是 "message_id → messages.ROWID"，而是
//    "message_global_data.message_id == messages.message_id"（两边都叫 message_id，
//    但都不是 ROWID；本机验证 messages.ROWID 与 messages.message_id 从不相等）。
// 2. Gmail 风格账户里，消息物理落在 "All Mail" 邮箱（messages.mailbox 指向它），
//    INBOX 只是一个"标签"，成员关系记录在 labels(message_id, mailbox_id) 表里，
//    不会出现在 messages.mailbox 里。因此按 mailbox 取信必须同时看
//    "messages.mailbox = 目标邮箱" 和 "labels 表里挂了目标邮箱" 两种情况，否则
//    Gmail 账户的 INBOX 会查出 0 封信（iCloud 账户走的是前一种，不受影响，
//    这正是 lead 的单邮件 iCloud spike 没能发现这个坑的原因）。

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class EnvelopeIndexProvider: MailDataProvider {

    enum ProviderError: Error, CustomStringConvertible {
        case noMailDirectoryFound
        case cannotOpenDatabase(path: String, message: String)
        case missingTable(String)
        case missingColumn(table: String, column: String)
        case queryFailed(String)

        var description: String {
            switch self {
            case .noMailDirectoryFound:
                return "No ~/Library/Mail/V*/MailData/Envelope Index found"
            case .cannotOpenDatabase(let path, let message):
                return "Cannot open \(path) read-only: \(message)"
            case .missingTable(let table):
                return "Required table '\(table)' missing/unreadable in Envelope Index (schema drift?)"
            case .missingColumn(let table, let column):
                return "Required column '\(table).\(column)' missing in Envelope Index (schema drift?)"
            case .queryFailed(let message):
                return "Query failed: \(message)"
            }
        }
    }

    private let db: OpaquePointer
    private let databaseURL: URL

    // MARK: - Init / schema validation

    /// 生产用：探测真实 ~/Library/Mail。
    convenience init() throws {
        let mailDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        try self.init(rootURL: mailDirectory)
    }

    /// 可测性入口（test-dev P1 建议）：`rootURL` 顶替 ~/Library/Mail，指向一个装了
    /// `V<N>/MailData/Envelope Index` 结构的任意目录（比如测试 fixture），方便不碰真实
    /// Mail 数据、不用 FDA 权限就能跑 schema 校验/查询逻辑的单测。其余行为（V 目录探测、
    /// schema 校验）与生产路径完全一致。
    init(rootURL: URL) throws {
        let url = try Self.locateEnvelopeIndex(mailDirectory: rootURL)
        self.databaseURL = url
        var handle: OpaquePointer?
        let uriPath = "file:\(url.path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let rc = sqlite3_open_v2(uriPath, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 rc=\(rc)"
            if let handle { sqlite3_close(handle) }
            throw ProviderError.cannotOpenDatabase(path: url.path, message: message)
        }
        self.db = handle
        try Self.validateSchema(db: handle)
    }

    deinit {
        sqlite3_close(db)
    }

    /// Envelope Index 所在的 MailData 目录（同一个 V 目录下）。RefreshScheduler 用它来
    /// 定位 `Envelope Index-wal` 挂文件监听，触发事件驱动刷新（契约 10）；纯只读用途，
    /// 这里不做任何写操作。
    var mailDataDirectoryURL: URL {
        databaseURL.deletingLastPathComponent()
    }

    /// 访问级别从 `private` 放宽到 internal（2026-08-26，DailyLinkAvailability 需求）：
    /// `MailLocalIndex.swift` 要打开自己的只读连接去查 `message_global_data`，需要复用
    /// 这份"探测最新 V 目录、拼出 Envelope Index 路径"的逻辑，避免第二份实现漂移。
    /// 行为完全不变，纯粹放宽可见性。
    static func locateEnvelopeIndex(mailDirectory: URL) throws -> URL {
        let mailDir = mailDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(at: mailDir, includingPropertiesForKeys: nil) else {
            throw ProviderError.noMailDirectoryFound
        }
        let vDirs: [(Int, URL)] = entries.compactMap { entryURL in
            let name = entryURL.lastPathComponent
            guard name.hasPrefix("V"), let number = Int(name.dropFirst()) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return (number, entryURL)
        }
        guard let newest = vDirs.max(by: { $0.0 < $1.0 }) else {
            throw ProviderError.noMailDirectoryFound
        }
        let dbURL = newest.1.appendingPathComponent("MailData").appendingPathComponent("Envelope Index")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw ProviderError.noMailDirectoryFound
        }
        return dbURL
    }

    /// 必需表 → 必需列（ROWID 天然存在，不单独校验）。
    private static let requiredColumns: [String: [String]] = [
        "messages": ["sender", "subject", "summary", "mailbox", "date_received", "read", "flagged", "deleted", "message_id"],
        "mailboxes": ["url", "unread_count"],
        "addresses": ["address", "comment"],
        "subjects": ["subject"],
        "summaries": ["summary"],
        "message_global_data": ["message_id", "message_id_header"],
        "labels": ["message_id", "mailbox_id"],
    ]

    private static func validateSchema(db: OpaquePointer) throws {
        for (table, columns) in requiredColumns {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw ProviderError.missingTable(table)
            }
            var found = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) {
                    found.insert(String(cString: name))
                }
            }
            sqlite3_finalize(stmt)
            guard !found.isEmpty else {
                throw ProviderError.missingTable(table)
            }
            for column in columns where !found.contains(column) {
                throw ProviderError.missingColumn(table: table, column: column)
            }
        }
    }

    // MARK: - MailDataProvider

    /// 每个（伪）邮箱最多回传的邮件数。2026-07-23 从 20 提到 50，给 widget 翻页
    /// （契约 9）提供浏览深度；Envelope 通道读本地 SQLite 很快，50 条查询/裁剪成本
    /// 可忽略。AppleScriptProvider 的兜底通道保持 10 不变——它要真的驱动 Mail.app
    /// 取每封信的内容，条数越多越慢，两个通道的取信成本不是一个量级。
    private static let messagesPerMailboxLimit = 50

    func fetchSnapshot() throws -> MailSnapshot {
        let inboxRows = try queryInboxMailboxes().sorted { $0.url < $1.url }
        let vipAddresses = loadVIPAddressesLowercased()

        var accounts: [AccountSummary] = []
        for (index, row) in inboxRows.enumerated() {
            guard let key = Self.parseAccountKey(fromURL: row.url) else { continue }
            let accountMailboxRowIDs = try mailboxRowIDs(scheme: key.scheme, authority: key.authority)

            var mailboxes: [MailboxSummary] = []

            let inboxMessages = try messagesInMailbox(rowID: row.rowID, limit: Self.messagesPerMailboxLimit)
            mailboxes.append(MailboxSummary(
                id: row.url,
                name: "Inbox",
                role: "inbox",
                unreadCount: row.unreadCount,
                messages: inboxMessages.map(Self.convert)
            ))

            let flagged = try messagesForAccount(
                rowIDs: accountMailboxRowIDs, flaggedOnly: true, vipAddressesLowercased: nil, limit: Self.messagesPerMailboxLimit
            )
            if flagged.unreadCount > 0 || !flagged.messages.isEmpty {
                mailboxes.append(MailboxSummary(
                    id: "flagged://\(key.authority)",
                    name: "Flagged",
                    role: "flagged",
                    unreadCount: flagged.unreadCount,
                    messages: flagged.messages.map(Self.convert)
                ))
            }

            if !vipAddresses.isEmpty {
                let vip = try messagesForAccount(
                    rowIDs: accountMailboxRowIDs, flaggedOnly: false, vipAddressesLowercased: vipAddresses, limit: Self.messagesPerMailboxLimit
                )
                if !vip.messages.isEmpty {
                    mailboxes.append(MailboxSummary(
                        id: "vip://\(key.authority)",
                        name: "VIP",
                        role: "vip",
                        unreadCount: vip.unreadCount,
                        messages: vip.messages.map(Self.convert)
                    ))
                }
            }

            let identity = resolveAccountIdentity(uuid: key.authority, mailboxRowIDs: accountMailboxRowIDs, fallbackIndex: index + 1)
            accounts.append(AccountSummary(id: key.authority, name: identity.name, email: identity.email, mailboxes: mailboxes))
        }

        return MailSnapshot(generatedAt: Date(), providerKind: "envelopeIndex", accounts: accounts)
    }

    // MARK: - Queries

    private func queryInboxMailboxes() throws -> [(rowID: Int64, url: String, unreadCount: Int)] {
        let sql = "SELECT ROWID, url, unread_count FROM mailboxes WHERE url LIKE '%/INBOX'"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ProviderError.queryFailed("inbox mailboxes: \(String(cString: sqlite3_errmsg(db)))")
        }
        var results: [(Int64, String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)
            let url = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let unread = Int(sqlite3_column_int64(stmt, 2))
            results.append((rowID, url, unread))
        }
        return results
    }

    private func mailboxRowIDs(scheme: String, authority: String) throws -> [Int64] {
        let sql = "SELECT ROWID FROM mailboxes WHERE url LIKE ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ProviderError.queryFailed("account mailbox rowids: \(String(cString: sqlite3_errmsg(db)))")
        }
        let pattern = "\(scheme)://\(authority)/%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    /// 取某个邮箱里的信：既看 messages.mailbox 直存，也看 labels 表挂的标签
    /// （Gmail 风格账户的 INBOX/Important 等都是纯标签，见文件头注释）。
    private func messagesInMailbox(rowID: Int64, limit: Int) throws -> [RawMessage] {
        let sql = """
        SELECT \(Self.messageSelectColumns)
        \(Self.messageJoins)
        WHERE m.deleted = 0 AND (m.mailbox = ?1 OR EXISTS (
            SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id = ?1
        ))
        ORDER BY m.date_received DESC
        LIMIT ?2
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ProviderError.queryFailed("messages in mailbox: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_bind_int64(stmt, 1, rowID)
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        var results: [RawMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(Self.rawMessage(from: stmt))
        }
        return results
    }

    /// 账户级聚合（flagged / VIP 伪邮箱）：在该账户拥有的全部邮箱 ROWID 集合上过滤。
    /// 这些 ROWID 已经包含 Gmail 风格账户的 "All Mail"（消息的真实落地邮箱），
    /// 所以这里不需要再叠加 labels 表的 union。
    private func messagesForAccount(
        rowIDs: [Int64],
        flaggedOnly: Bool,
        vipAddressesLowercased: Set<String>?,
        limit: Int
    ) throws -> (unreadCount: Int, messages: [RawMessage]) {
        guard !rowIDs.isEmpty else { return (0, []) }

        let vipList = vipAddressesLowercased.map(Array.init) ?? []
        var conditions = ["m.deleted = 0", "m.mailbox IN (\(placeholders(rowIDs.count)))"]
        if flaggedOnly {
            conditions.append("m.flagged = 1")
        }
        if !vipList.isEmpty {
            conditions.append("lower(a.address) IN (\(placeholders(vipList.count)))")
        }
        let whereClause = conditions.joined(separator: " AND ")

        // Unread count.
        let countSQL = "SELECT COUNT(*) FROM messages m LEFT JOIN addresses a ON m.sender = a.ROWID WHERE \(whereClause) AND m.read = 0"
        var countStmt: OpaquePointer?
        defer { sqlite3_finalize(countStmt) }
        guard sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK, let countStmt else {
            throw ProviderError.queryFailed("account unread count: \(String(cString: sqlite3_errmsg(db)))")
        }
        var idx = Self.bind(rowIDs, into: countStmt, startingAt: 1)
        if !vipList.isEmpty {
            idx = Self.bind(vipList, into: countStmt, startingAt: idx)
        }
        var unreadCount = 0
        if sqlite3_step(countStmt) == SQLITE_ROW {
            unreadCount = Int(sqlite3_column_int64(countStmt, 0))
        }

        // Message list.
        let selectSQL = """
        SELECT \(Self.messageSelectColumns)
        \(Self.messageJoins)
        WHERE \(whereClause)
        ORDER BY m.date_received DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ProviderError.queryFailed("account messages: \(String(cString: sqlite3_errmsg(db)))")
        }
        idx = Self.bind(rowIDs, into: stmt, startingAt: 1)
        if !vipList.isEmpty {
            idx = Self.bind(vipList, into: stmt, startingAt: idx)
        }
        sqlite3_bind_int64(stmt, idx, Int64(limit))

        var results: [RawMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(Self.rawMessage(from: stmt))
        }
        return (unreadCount, results)
    }

    private func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    @discardableResult
    private static func bind(_ values: [Int64], into stmt: OpaquePointer?, startingAt start: Int32) -> Int32 {
        var idx = start
        for value in values {
            sqlite3_bind_int64(stmt, idx, value)
            idx += 1
        }
        return idx
    }

    @discardableResult
    private static func bind(_ values: [String], into stmt: OpaquePointer?, startingAt start: Int32) -> Int32 {
        var idx = start
        for value in values {
            sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
            idx += 1
        }
        return idx
    }

    // MARK: - Row decoding

    private static let messageSelectColumns = "m.ROWID, a.address, a.comment, s.subject, su.summary, m.date_received, m.read, m.flagged, mgd.message_id_header"
    private static let messageJoins = """
    FROM messages m
    LEFT JOIN addresses a ON m.sender = a.ROWID
    LEFT JOIN subjects s ON m.subject = s.ROWID
    LEFT JOIN summaries su ON m.summary = su.ROWID
    LEFT JOIN message_global_data mgd ON mgd.message_id = m.message_id
    """

    private struct RawMessage {
        let rowID: Int64
        let senderAddress: String?
        let senderName: String?
        let subject: String?
        let summary: String?
        let dateReceived: Double?
        let isRead: Bool
        let isFlagged: Bool
        let messageIdHeader: String?
    }

    private static func rawMessage(from stmt: OpaquePointer) -> RawMessage {
        let rowID = sqlite3_column_int64(stmt, 0)
        let address = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
        let comment = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let subject = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let summary = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let dateReceived: Double? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)
        let read = sqlite3_column_int64(stmt, 6) != 0
        let flagged = sqlite3_column_int64(stmt, 7) != 0
        let header = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        return RawMessage(
            rowID: rowID, senderAddress: address, senderName: comment, subject: subject, summary: summary,
            dateReceived: dateReceived, isRead: read, isFlagged: flagged, messageIdHeader: header
        )
    }

    private static func convert(_ raw: RawMessage) -> MessageSummary {
        let header = stripAngleBrackets(raw.messageIdHeader)
        let id = header ?? String(raw.rowID)
        let hasDisplayName = (raw.senderName?.isEmpty == false)
        let senderName = hasDisplayName ? raw.senderName! : (raw.senderAddress ?? "")
        return MessageSummary(
            id: id,
            messageIdHeader: header,
            sender: senderName,
            senderEmail: raw.senderAddress ?? "",
            subject: raw.subject ?? "",
            snippet: makeSnippet(raw.summary),
            date: Date(timeIntervalSince1970: raw.dateReceived ?? 0),
            isRead: raw.isRead,
            isFlagged: raw.isFlagged
        )
    }

    private static func stripAngleBrackets(_ value: String?) -> String? {
        guard var result = value, !result.isEmpty else { return nil }
        if result.hasPrefix("<") { result.removeFirst() }
        if result.hasSuffix(">") { result.removeLast() }
        return result.isEmpty ? nil : result
    }

    private static func makeSnippet(_ raw: String?) -> String {
        guard let raw else { return "" }
        let collapsed = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 120 else { return collapsed }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: 117)
        return String(collapsed[..<cutoff]) + "…"
    }

    // MARK: - Account key / identity resolution

    private static func parseAccountKey(fromURL url: String) -> (scheme: String, authority: String)? {
        guard let schemeRange = url.range(of: "://") else { return nil }
        let scheme = String(url[url.startIndex..<schemeRange.lowerBound])
        let rest = url[schemeRange.upperBound...]
        guard let slashIndex = rest.firstIndex(of: "/") else { return nil }
        let authority = String(rest[rest.startIndex..<slashIndex])
        guard !authority.isEmpty else { return nil }
        return (scheme, authority)
    }

    /// 账户显示名/邮箱解析，三级兜底：
    /// 1) macOS Accounts.framework 的 ~/Library/Accounts/Accounts4.sqlite（ZACCOUNT.ZIDENTIFIER），
    ///    命中且非空才用。已知局限：Mail 内部账户 UUID 只对通过"系统设置 > 互联网账户"配置的
    ///    账户（本机验证：iCloud、"On My Mac"）才会和 Accounts.framework 的 ZIDENTIFIER 一致；
    ///    直接在 Mail.app 里添加的 IMAP/Gmail 账户用的是 Mail 私有 UUID，这条会落空。
    /// 2) 返工新增的启发式：该账户收件箱消息在 `recipients` 表里最高频的收件地址（type=0，
    ///    即 To 收件人）≈ 账户自己的邮箱——本机 4 个账户实测全部命中且都是唯一显著占优的
    ///    地址（次高频地址的命中数远低于第一名），用它同时当 name 和 email；如果这条地址
    ///    在 addresses.comment 里留了真实显示名，顺手拿来当更友好的 name（比单纯拿地址当
    ///    name 更好看，属于超出字面要求的增强，若不想要可以去掉）。
    /// 3) 两条都落空才兜底 "Account N" + 空邮箱。
    private func resolveAccountIdentity(uuid: String, mailboxRowIDs: [Int64], fallbackIndex: Int) -> (name: String, email: String) {
        if let hit = Self.lookupAccountsFramework(uuid: uuid), let name = hit.name, !name.isEmpty {
            return (name, hit.email ?? "")
        }
        if let heuristic = resolveIdentityViaRecipientsHeuristic(mailboxRowIDs: mailboxRowIDs) {
            return heuristic
        }
        return ("Account \(fallbackIndex)", "")
    }

    /// 启发式：账户收件箱里最高频的 To 收件地址 ≈ 账户自己的邮箱。
    private func resolveIdentityViaRecipientsHeuristic(mailboxRowIDs rowIDs: [Int64]) -> (name: String, email: String)? {
        guard !rowIDs.isEmpty else { return nil }
        let sql = """
        SELECT a.address, a.comment, COUNT(*) as cnt
        FROM recipients r
        JOIN messages m ON r.message = m.ROWID
        JOIN addresses a ON r.address = a.ROWID
        WHERE m.mailbox IN (\(placeholders(rowIDs.count))) AND r.type = 0 AND m.deleted = 0
        GROUP BY a.address
        ORDER BY cnt DESC
        LIMIT 1
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        Self.bind(rowIDs, into: stmt, startingAt: 1)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let addressText = sqlite3_column_text(stmt, 0) else { return nil }
        let address = String(cString: addressText)
        guard !address.isEmpty else { return nil }
        let comment = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let name = comment.isEmpty ? address : comment
        return (name, address)
    }

    private static func lookupAccountsFramework(uuid: String) -> (name: String?, email: String?)? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Accounts/Accounts4.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var handle: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(handle) }

        let sql = "SELECT ZACCOUNTDESCRIPTION, ZUSERNAME FROM ZACCOUNT WHERE ZIDENTIFIER = ? LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let description = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
        let username = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
        return (description, username)
    }

    // MARK: - VIP

    /// 结构无关的 VIP 名单解析：递归遍历 plist 对象图，收集所有形似邮箱地址的字符串叶子。
    /// 本机 VIPMailboxes.plist 为空 {}，无法实测真实 key 名；解析不出就返回空集合，
    /// 上层据此跳过 VIP 伪邮箱（与 frontend 已知 VIP 可能缺失一致）。
    private func loadVIPAddressesLowercased() -> Set<String> {
        let plistURL = databaseURL.deletingLastPathComponent().appendingPathComponent("VIPMailboxes.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return []
        }
        var found = Set<String>()
        func walk(_ value: Any) {
            switch value {
            case let s as String:
                if s.contains("@"), s.contains(".") {
                    found.insert(s.lowercased())
                }
            case let array as [Any]:
                array.forEach(walk)
            case let dict as [String: Any]:
                dict.values.forEach(walk)
            default:
                break
            }
        }
        walk(object)
        return found
    }
}
