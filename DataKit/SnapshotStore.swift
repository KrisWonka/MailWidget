// SnapshotStore.swift
// DataKit — 契约 2：SnapshotStore.load() -> MailSnapshot? / save(_:)。
// 路径 = App Group 容器下 snapshot.json；容器不可用时（如 CLI 测试环境）降级到
// ~/Library/Application Support/MailWidget/snapshot.json。原子写入，JSON 用 .iso8601 日期策略。

import Foundation
import WidgetKit

enum SnapshotStore {

    enum StoreError: Error, CustomStringConvertible {
        case cannotResolveFallbackDirectory
        case encodingFailed(Error)
        case writeFailed(Error)

        var description: String {
            switch self {
            case .cannotResolveFallbackDirectory:
                return "Cannot resolve fallback Application Support directory"
            case .encodingFailed(let error):
                return "Failed to encode MailSnapshot: \(error)"
            case .writeFailed(let error):
                return "Failed to write snapshot.json: \(error)"
            }
        }
    }

    private static let fileName = "snapshot.json"

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

    /// App Group 容器 URL；不可用（如在无 entitlement 的 CLI harness 里运行）时为 nil。
    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier)
    }

    /// 降级路径：~/Library/Application Support/MailWidget/snapshot.json
    private static var fallbackDirectoryURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("MailWidget", isDirectory: true)
    }

    /// 实际使用的快照文件 URL：优先 App Group 容器，否则降级路径。
    static var snapshotFileURL: URL? {
        if let containerURL {
            return containerURL.appendingPathComponent(fileName)
        }
        return fallbackDirectoryURL?.appendingPathComponent(fileName)
    }

    /// 读取最近一次快照。nil = 从未生成（容器/降级目录里没有文件，或文件无法解码）。
    static func load() -> MailSnapshot? {
        guard let url = snapshotFileURL,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(MailSnapshot.self, from: data)
    }

    /// 原子写入最新快照。
    static func save(_ snapshot: MailSnapshot) throws {
        guard let url = snapshotFileURL else {
            throw StoreError.cannotResolveFallbackDirectory
        }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.writeFailed(error)
        }
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw StoreError.encodingFailed(error)
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw StoreError.writeFailed(error)
        }
    }

    /// 契约 10 — 乐观已读标记：点邮件把 message:// 转发给 Mail.app 之后，宿主 app 不用等
    /// 下一轮定时/文件监听刷新，先在本地快照里就地把这封信标成已读，widget 蓝点立刻消失。
    ///
    /// 一封信可能同时出现在 inbox 和 vip/flagged 等伪邮箱里（同一个 messageIdHeader），
    /// 全部要改，不只改第一处命中的。MessageSummary/MailboxSummary 字段都是 let，
    /// 这里是整体重建一份新 struct，不是"就地 mutate"字面意义上的原地改。
    ///
    /// 返回是否真的有变更（没匹配到、或匹配到的信本来就是已读，返回 false，不做任何
    /// 落盘/reload）。找不到快照（load() 为 nil）也返回 false。
    @discardableResult
    static func applyLocalReadMark(messageIdHeader: String) -> Bool {
        let target = messageIdHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, let snapshot = load() else { return false }

        var changed = false
        let updatedAccounts = snapshot.accounts.map { account -> AccountSummary in
            let updatedMailboxes = account.mailboxes.map { mailbox -> MailboxSummary in
                var newlyReadCount = 0
                let updatedMessages = mailbox.messages.map { message -> MessageSummary in
                    guard message.messageIdHeader == target, !message.isRead else {
                        return message
                    }
                    newlyReadCount += 1
                    return MessageSummary(
                        id: message.id,
                        messageIdHeader: message.messageIdHeader,
                        sender: message.sender,
                        senderEmail: message.senderEmail,
                        subject: message.subject,
                        snippet: message.snippet,
                        date: message.date,
                        isRead: true,
                        isFlagged: message.isFlagged
                    )
                }
                guard newlyReadCount > 0 else { return mailbox }
                changed = true
                return MailboxSummary(
                    id: mailbox.id,
                    name: mailbox.name,
                    role: mailbox.role,
                    unreadCount: max(0, mailbox.unreadCount - newlyReadCount),
                    messages: updatedMessages
                )
            }
            return AccountSummary(id: account.id, name: account.name, email: account.email, mailboxes: updatedMailboxes)
        }

        guard changed else { return false }

        // 这是本地补丁，不是一次真的重新抓取：保留原 generatedAt/providerKind，
        // 免得"数据过期"判定被这次标记动作误导成"刚刚才抓取过"。
        let patched = MailSnapshot(generatedAt: snapshot.generatedAt, providerKind: snapshot.providerKind, accounts: updatedAccounts)

        do {
            try save(patched)
        } catch {
            return false
        }
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }

    /// 契约 11 — 一键"全部已读"的乐观清零（对应真标记 `MailAppOpener.markAllRead`）。
    /// `scopeID` 和 extension 的 MailScopeEntity 用同一套字符串："all" = 快照里所有
    /// 账户的所有邮箱；"account:<id>" = 仅该账户的所有邮箱。本轮不支持 vip/flagged
    /// scope（frontend 这两种 scope 不显示"全部已读"按钮），传别的字符串一律无操作。
    ///
    /// "所有邮箱"包括 inbox/vip/flagged 等各种 role，不只 inbox——一旦某邮箱在范围内，
    /// 它底下不管什么角色都清零。mailbox.unreadCount 是邮箱的真实未读总数，可能比
    /// messages 数组里能看到的条数（50/10 上限）还大；所以哪怕数组里当前一封未读都没有，
    /// 只要 unreadCount 本来 > 0 也算"有变更"，一并清零，不能靠"数组里翻了几封"来判断。
    ///
    /// 返回是否真的有变更；找不到快照、或 scopeID 无法识别、或范围内本来就全部已读，
    /// 都返回 false，不做任何落盘/reload。
    @discardableResult
    static func applyLocalMarkAllRead(scopeID: String) -> Bool {
        guard let snapshot = load() else { return false }

        let accountScopePrefix = "account:"
        let targetAccountID: String? = scopeID.hasPrefix(accountScopePrefix)
            ? String(scopeID.dropFirst(accountScopePrefix.count))
            : nil
        guard scopeID == "all" || targetAccountID != nil else { return false }

        var changed = false
        let updatedAccounts = snapshot.accounts.map { account -> AccountSummary in
            guard scopeID == "all" || account.id == targetAccountID else { return account }
            let updatedMailboxes = account.mailboxes.map { mailbox -> MailboxSummary in
                let updatedMessages = mailbox.messages.map { message -> MessageSummary in
                    guard !message.isRead else { return message }
                    return MessageSummary(
                        id: message.id,
                        messageIdHeader: message.messageIdHeader,
                        sender: message.sender,
                        senderEmail: message.senderEmail,
                        subject: message.subject,
                        snippet: message.snippet,
                        date: message.date,
                        isRead: true,
                        isFlagged: message.isFlagged
                    )
                }
                let anyMessageFlipped = zip(mailbox.messages, updatedMessages).contains { !$0.isRead && $1.isRead }
                guard anyMessageFlipped || mailbox.unreadCount != 0 else { return mailbox }
                changed = true
                return MailboxSummary(
                    id: mailbox.id,
                    name: mailbox.name,
                    role: mailbox.role,
                    unreadCount: 0,
                    messages: updatedMessages
                )
            }
            return AccountSummary(id: account.id, name: account.name, email: account.email, mailboxes: updatedMailboxes)
        }

        guard changed else { return false }

        let patched = MailSnapshot(generatedAt: snapshot.generatedAt, providerKind: snapshot.providerKind, accounts: updatedAccounts)
        do {
            try save(patched)
        } catch {
            return false
        }
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }
}
