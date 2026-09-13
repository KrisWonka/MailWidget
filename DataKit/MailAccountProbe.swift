// MailAccountProbe.swift
// DataKit — 诊断 Mail.app 里有没有配置真实邮件账户。
//
// 真机部署实录：朋友的 Mail.app 一个真实账户都没有（只有本地 Drafts/Outbox，Envelope
// Index 里只有 1 封 2024 年的草稿），于是收件箱 widget 和邮件总结全是空的——但没有任何
// 提示告诉他原因，看起来像 app 坏了。这里补一个只读诊断，供 frontend 在 widget/设置页
// 判断要不要显示"请先在邮件 App 里添加账户"。
//
// 判据：Envelope Index 的 mailboxes 表里存在 url 以远程协议（imap://、ews://、pop:// 等）
// 开头的行——`local://` 是本地伪邮箱（Drafts/Outbox/On My Mac），不算数。
//
// 不确定时（打不开数据库、schema 对不上）返回 true：宁可在没有完全磁盘访问的机器上
// 什么提示都不显示，也不要在"其实有账户，只是我们读不到"的情况下误报"没有账户"。

import Foundation
import SQLite3

extension ProviderProbe {
    /// Mail.app 里有没有配置真实邮件账户（不含本地 Drafts/Outbox 这类伪邮箱）。
    static func hasConfiguredMailAccounts() -> Bool {
        hasConfiguredMailAccounts(
            mailDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        )
    }

    /// 可测性入口：`mailDirectory` 顶替 ~/Library/Mail，指向任意装了
    /// `V<N>/MailData/Envelope Index` 结构的目录，方便单测/fixture 不碰真实 Mail 数据。
    static func hasConfiguredMailAccounts(mailDirectory: URL) -> Bool {
        guard let urls = try? mailboxURLs(mailDirectory: mailDirectory) else {
            return true
        }
        return containsRemoteMailbox(urls: urls)
    }

    /// 纯判定：至少一行 `mailboxes.url` 是非 `local://` 的远程协议，即视为"配置了真实
    /// 邮件账户"。用"非 local://"而不是维护一份远程协议白名单——Mail.app 支持的账户类型
    /// （imap/ews/pop/exchange……）会变，但"是不是本地伪邮箱"这个二分法不会变。
    static func containsRemoteMailbox(urls: [String]) -> Bool {
        urls.contains { url in
            url.contains("://") && !url.hasPrefix("local://")
        }
    }

    // MARK: - IO

    private enum MailAccountProbeError: Error {
        case cannotOpenDatabase
        case queryFailed
    }

    private static func mailboxURLs(mailDirectory: URL) throws -> [String] {
        let dbURL = try EnvelopeIndexProvider.locateEnvelopeIndex(mailDirectory: mailDirectory)

        var handle: OpaquePointer?
        let uriPath = "file:\(dbURL.path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uriPath, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw MailAccountProbeError.cannotOpenDatabase
        }
        defer { sqlite3_close(handle) }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, "SELECT url FROM mailboxes", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MailAccountProbeError.queryFailed
        }

        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: text))
            }
        }
        return results
    }
}
