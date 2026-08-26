// MailLocalIndex.swift
// DataKit — 批量查询「这些邮件是否已经同步进本地 Mail 库」，与快照命中与否无关。
//
// 起因（2026-08-26）：DailyBriefItem.mailURL 早先只要载荷里有 Message-ID 就给
// `message://` 深链，理由是"快照只索引每邮箱最多 50 封，没命中不代表 Mail 里没有
// 这封信"。这个理由在快照窗口内成立，但漏了另一种更根本的情况——日报总结的是
// Gmail 里刚收到的新信，本地 Mail 账户的 IMAP 同步还没追上，那封信在**整个本地
// Envelope Index 里都不存在**，点开只会弹 `MCMailErrorDomain error 1030`。
// 快照命中与否解决不了这个问题（它天然只看最近 50 封），必须直接查整个库。
//
// 这里不用 EnvelopeIndexProvider 的实例——它只暴露 fetchSnapshot()，没有"存在性
// 查询"这个操作，硬套的话要么改它的公开面、要么在外面重新拼一次 mailbox 枚举，
// 都不如直接开一条独立的只读连接来得直接。复用的只是 EnvelopeIndexProvider 里
// "探测最新 V 目录、拼出 Envelope Index 路径"这段逻辑（放宽访问级别后直接调用），
// 避免第二份路径探测实现跟着 V 目录升级各自漂移。
//
// 只读、只查 `message_global_data.message_id_header`：这张表本来就是
// EnvelopeIndexProvider 校验过的必需表（见其 requiredColumns），本文件不重复做
// 全量 schema 校验——查询语句本身失败（表/列缺失、库不可读）就地捕获，那一批
// 头部保持"没有记录"（不写入返回的字典），由调用方按"未知"处理，不当作 false。

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MailLocalIndex {

    /// 单次 IN 查询携带的 Message-ID 上限（每个 header 还会额外带一份尖括号形态，
    /// 所以一批最多绑定 100 个参数）。
    private static let batchSize = 50

    /// 批量查询：`messageIdHeaders` 不含尖括号（与契约里 messageIdHeader 字段的形态
    /// 一致）。返回值只包含"真的查到了结果"的 header——库整体不可用（无完全磁盘
    /// 访问权限、Mail 目录不存在、schema 漂移）时返回空字典；单个 header 没在库里
    /// 查到才是明确的 `false`。调用方据此区分"确认没有"和"不知道"。
    static func existsLocally(messageIdHeaders: [String]) -> [String: Bool] {
        let uniqueHeaders = Array(Set(
            messageIdHeaders
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        ))
        guard !uniqueHeaders.isEmpty else { return [:] }

        guard let db = try? openReadOnlyEnvelopeIndex() else {
            return [:]
        }
        defer { sqlite3_close(db) }

        var result: [String: Bool] = [:]
        for start in stride(from: 0, to: uniqueHeaders.count, by: batchSize) {
            let end = min(start + batchSize, uniqueHeaders.count)
            let batch = Array(uniqueHeaders[start..<end])
            guard let found = queryExistingHeaders(batch, db: db) else {
                // 这一批查询失败（理论上不该发生——库都能开了——但万一遇到 schema
                // 漂移就地兜底）：不写入这些 header，调用方看到"没有记录"会按未知处理。
                continue
            }
            for header in batch {
                result[header] = found.contains(header) || found.contains("<\(header)>")
            }
        }
        return result
    }

    // MARK: - 只读连接

    private static func openReadOnlyEnvelopeIndex() throws -> OpaquePointer {
        let mailDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail")
        let dbURL = try EnvelopeIndexProvider.locateEnvelopeIndex(mailDirectory: mailDirectory)

        var handle: OpaquePointer?
        let uriPath = "file:\(dbURL.path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let rc = sqlite3_open_v2(uriPath, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw OpenError.cannotOpen
        }
        return handle
    }

    private enum OpenError: Error {
        case cannotOpen
    }

    // MARK: - 查询

    /// 一批 header 各自既查裸形态又查带尖括号形态（历史数据两种都有，见文件头注释）；
    /// 返回值是数据库里真的存在的原始字符串集合（裸的或带尖括号的都可能出现），
    /// 调用方再拿每个原始 header 去两种形态里对一遍。查询本身失败（prepare 出错）
    /// 返回 nil，与"查了但没找到"（返回空集合）区分开。
    private static func queryExistingHeaders(_ headers: [String], db: OpaquePointer) -> Set<String>? {
        guard !headers.isEmpty else { return [] }

        let placeholders = Array(repeating: "?,?", count: headers.count).joined(separator: ",")
        let sql = "SELECT DISTINCT message_id_header FROM message_global_data WHERE message_id_header IN (\(placeholders))"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }

        var idx: Int32 = 1
        for header in headers {
            sqlite3_bind_text(stmt, idx, header, -1, SQLITE_TRANSIENT)
            idx += 1
            sqlite3_bind_text(stmt, idx, "<\(header)>", -1, SQLITE_TRANSIENT)
            idx += 1
        }

        var found = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                found.insert(String(cString: text))
            }
        }
        return found
    }
}
