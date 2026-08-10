// MailSummaryStore.swift
// DataKit — 契约 12：邮件总结在 App Group 容器里的读写。
//
// 与 SnapshotStore 同款手法：App Group 容器不可用时（如无 entitlement 的 CLI 测试环境）
// 降级到 ~/Library/Application Support/MailWidget/，原子写入，JSON 用 .iso8601 日期策略。
// 与 SnapshotStore 的差别只在于这里没有"读旧值→就地改→存回"的乐观补丁操作（那是
// SnapshotStore 应对已读标记这种局部更新才需要的），所以串行队列只用来串行化
// load/save 本身，不需要 xxxLocked 变体。
//
// 一个 scopeID 对应一个文件：`mail-summary-<scopeID 的 SHA256 前 16 位十六进制>.json`。
// 全量哈希而不是"只替换非字母数字字符"，是为了让文件名生成规则简单、无歧义、
// 天然满足文件系统安全字符集，且"同一 scope 恒定同一文件"这条要求靠哈希的确定性
// 直接满足，不用再额外证明"部分替换"方案不会在不同 scopeID 之间产生碰撞。

import Foundation
import CryptoKit

struct MailSummaryItem: Codable {
    let messageIdHeader: String
    let sender: String
    let subject: String
    let summaryTitle: String
    let summaryDetail: String
}

struct MailSummary: Codable {
    let schemaVersion: Int
    let scopeID: String
    let scopeName: String
    let generatedAt: Date
    let items: [MailSummaryItem]
}

struct MailSummaryStore {

    enum StoreError: Error, CustomStringConvertible {
        case containerUnavailable
        case encodingFailed(Error)
        case writeFailed(Error)
        case readFailed(Error)
        case decodingFailed(Error)

        var description: String {
            switch self {
            case .containerUnavailable:
                return "Cannot resolve App Group container or fallback Application Support directory"
            case .encodingFailed(let error):
                return "Failed to encode MailSummary: \(error)"
            case .writeFailed(let error):
                return "Failed to write mail summary file: \(error)"
            case .readFailed(let error):
                return "Failed to read mail summary file: \(error)"
            case .decodingFailed(let error):
                return "Failed to decode mail summary file: \(error)"
            }
        }
    }

    /// 串行化同一进程内的 load/save，避免并发写把文件写坏（跟 SnapshotStore.ioQueue
    /// 同样的动机，规模小一些：这里没有读-改-写序列，只有整体 save，串行队列纯粹是
    /// 防止两次几乎同时的 save 交错写入同一文件）。
    private static let ioQueue = DispatchQueue(label: "com.kris.mailwidget.mailSummaryStore.io")

    private let containerURL: URL?

    /// App Group 容器（`SharedConstants.appGroupIdentifier`）；不可用时降级到
    /// ~/Library/Application Support/MailWidget/，跟 SnapshotStore 的降级路径同款手法。
    init() {
        let fileManager = FileManager.default
        if let appGroupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier
        ) {
            self.containerURL = appGroupURL
        } else if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.containerURL = appSupport.appendingPathComponent("MailWidget", isDirectory: true)
        } else {
            self.containerURL = nil
        }
    }

    /// 单测注入：直接指定容器目录（通常是临时目录），绕开 App Group entitlement。
    init(containerURL: URL) {
        self.containerURL = containerURL
    }

    private static var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static var decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// scopeID → 稳定文件名：SHA256(scopeID) 的前 16 位十六进制。同一 scopeID 永远
    /// 映射到同一个文件名；不同 scopeID 几乎不可能碰撞（16 位十六进制 = 64 bit）。
    static func fileName(forScopeID scopeID: String) -> String {
        let digest = SHA256.hash(data: Data(scopeID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "mail-summary-\(hex.prefix(16)).json"
    }

    private func fileURL(forScopeID scopeID: String) -> URL? {
        containerURL?.appendingPathComponent(Self.fileName(forScopeID: scopeID), isDirectory: false)
    }

    /// 读取该 scope 最近一次总结。nil = 从未生成过（文件不存在）；文件存在但读取/解码
    /// 失败时抛错，不悄悄吞掉——那样会让"生成失败"和"从未生成"在 UI 上无法区分。
    func load(scopeID: String) throws -> MailSummary? {
        try Self.ioQueue.sync {
            guard let url = fileURL(forScopeID: scopeID) else {
                throw StoreError.containerUnavailable
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw StoreError.readFailed(error)
            }
            do {
                return try Self.decoder.decode(MailSummary.self, from: data)
            } catch {
                throw StoreError.decodingFailed(error)
            }
        }
    }

    /// 原子写入：先编码整份数据再落盘，编码失败时一个字节都不写，上一份有效总结
    /// 不会被半成品顶掉。
    func save(_ summary: MailSummary) throws {
        try Self.ioQueue.sync {
            guard let url = fileURL(forScopeID: summary.scopeID) else {
                throw StoreError.containerUnavailable
            }
            let directory = url.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw StoreError.writeFailed(error)
            }
            let data: Data
            do {
                data = try Self.encoder.encode(summary)
            } catch {
                throw StoreError.encodingFailed(error)
            }
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                throw StoreError.writeFailed(error)
            }
        }
    }
}
