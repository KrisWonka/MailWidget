// SnapshotStore.swift
// DataKit — 契约 2：SnapshotStore.load() -> MailSnapshot? / save(_:)。
// 路径 = App Group 容器下 snapshot.json；容器不可用时（如 CLI 测试环境）降级到
// ~/Library/Application Support/MailWidget/snapshot.json。原子写入，JSON 用 .iso8601 日期策略。
//
// 阶段三 review 批 1 arch-High #3 修复：宿主 app 进程内有三个写入方——
// RefreshScheduler 定时/WAL 触发的整体覆盖式 `save`，以及 `applyLocalReadMark` /
// `applyLocalMarkAllRead` 这两个"读旧值→就地改→存回"的乐观标记——原先各自独立
// load+save，互相之间没有互斥，交错执行会丢更新（比如：定时刷新已经读到了旧快照、
// 正在慢慢抓取的时候，用户点了一封信触发乐观标记，标记 save 完之后，刷新那边拿着
// 抓取前读到的旧状态整体覆盖回去，标记就凭空消失了）。现在这四个入口（load 也算，
// 保持对称）统一经过下面的私有串行队列 `ioQueue`，队列内一律用 `xxxLocked` 变体，
// 禁止在队列内部再调用会重新 `ioQueue.sync` 的公开入口——那会在同一个串行队列上
// 自己等自己，死锁。
//
// 残余语义（刻意不处理，写在这里免得以后被当成 bug 重新"修"一遍）：如果刷新的
// 抓取本身（不在锁内，抓取可能耗时数百毫秒到几秒）跨越了一次乐观标记，刷新完成后
// 的整体覆盖式 save 仍然会讨论掉抓取开始之后、覆盖之前发生的那次乐观标记——串行化
// 解决的是"两次 load-modify-save 交错导致写坏/losing 中间态"，不是"用旧快照做出的
// 决策最终会不会被更新的快照覆盖"。这属于"整体替换语义"固有的滞后，下一轮 WAL
// 变化触发的刷新会在几秒内重新看到 Mail 里的真实已读状态、自愈过来，不需要为此
// 引入锁以外的协调机制（比如给每条乐观标记打版本戳、合并而非整体替换）。

import Foundation
import WidgetKit

enum SnapshotStore {

    /// 串行化所有 load-modify-save 操作，让同一进程内的 `save` / `applyLocalReadMark` /
    /// `applyLocalMarkAllRead` 互斥执行。只在本进程（宿主 app）内有意义——widget
    /// extension 是单独的进程，只调用只读的 `load()`，不参与这里说的写竞态；文件本身
    /// 的原子性（`.atomic` 写选项）已经保证跨进程读到的永远是完整的旧或新内容，不会
    /// 读到写了一半的半成品，这个队列解决的是另一件事：同一进程内多个"读-改-写"
    /// 序列互相打断导致的更新丢失。
    private static let ioQueue = DispatchQueue(label: "com.kris.mailwidget.snapshotStore.io")

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
        ioQueue.sync { loadLocked() }
    }

    /// 原子写入最新快照。
    static func save(_ snapshot: MailSnapshot) throws {
        try ioQueue.sync { try saveLocked(snapshot) }
    }

    /// 只允许在已经持有 `ioQueue` 的调用路径里直接用（`applyLocalReadMark` /
    /// `applyLocalMarkAllRead` 内部）；对外的 `load()` 是它加锁后的包装。
    private static func loadLocked() -> MailSnapshot? {
        guard let url = snapshotFileURL,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(MailSnapshot.self, from: data)
    }

    /// 只允许在已经持有 `ioQueue` 的调用路径里直接用；对外的 `save(_:)` 是它加锁后的
    /// 包装。绝不能从 `ioQueue.sync` 块内部改调用公开的 `save(_:)`——那会在同一个
    /// 串行队列上再排一次队等自己，死锁。
    private static func saveLocked(_ snapshot: MailSnapshot) throws {
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
        guard !target.isEmpty else { return false }

        // 整个"读旧快照→算出补丁→写回"必须在同一次 ioQueue.sync 里完成，不能拆成
        // load() 一次调用、save() 另一次调用——拆开的话，两次调用之间这个进程里的
        // 其它写入方（RefreshScheduler 的整体覆盖 save、或另一次并发的乐观标记）
        // 有机会插进来，读到的 snapshot 就不是"即将被覆盖前最新的那份"了。
        let didChange: Bool = ioQueue.sync {
            guard let snapshot = loadLocked() else { return false }

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
                try saveLocked(patched)
            } catch {
                return false
            }
            return true
        }

        guard didChange else { return false }
        // reload 是跨进程 XPC 式的调用，不是"读-改-写"临界区的一部分，故意放在
        // ioQueue.sync 之外执行，不占着锁等它。
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }

    /// 契约 11 — 一键"全部已读"的乐观清零（对应真标记 `MailAppOpener.markAllRead`）。
    /// `scopeID` 和 extension 的 MailScopeEntity 用同一套字符串（唯一权威见
    /// `MailScope`）："all" = 快照里所有账户的所有邮箱；"account:<id>" = 仅该账户的
    /// 所有邮箱。本轮不支持 vip/flagged scope（frontend 这两种 scope 不显示"全部
    /// 已读"按钮），传别的字符串一律无操作——这个 fail-closed 行为本来就是对的，
    /// 批 1 review 修的是 `MailAppOpener.markAllRead` 那边的 nil 哨兵，不是这里。
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
        // 同 applyLocalReadMark：load-modify-save 整段收在一次 ioQueue.sync 里，
        // 不拆成两次公开调用。
        let didChange: Bool = ioQueue.sync {
            guard let snapshot = loadLocked() else { return false }

            let targetAccountID: String? = scopeID.hasPrefix(MailScope.accountPrefix)
                ? String(scopeID.dropFirst(MailScope.accountPrefix.count))
                : nil
            guard scopeID == MailScope.all || targetAccountID != nil else { return false }

            var changed = false
            let updatedAccounts = snapshot.accounts.map { account -> AccountSummary in
                guard scopeID == MailScope.all || account.id == targetAccountID else { return account }
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
                try saveLocked(patched)
            } catch {
                return false
            }
            return true
        }

        guard didChange else { return false }
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }
}
