// MailAppOpener.swift
// DataKit — 契约 8（新增）：从 mailwidget:// URL handler 中转过来，宿主 app 里
// 负责真正把 Mail.app 打开到具体邮件/邮箱。仅宿主 app 会调用；不经过 widget extension。
//
// deep link scheme 说明：统一用 `message://%3C<id>%3E`（双斜杠）——lead 已用 Foundation
// 实测确认 macOS 14+ 的新 URL 解析器允许 reg-name 里出现 pct-encoded 内容，"@" 不会被
// 拆成 authority 的 user@host，且 Hookmark/DEVONthink/org-mac-link 等生态多年都用这个
// 双斜杠形式；spec.md 契约 3 之前写的单冒号是笔误，已由 lead 改正。
//
// P0 修复记录（返工 3，AE 明文跟踪实锤）：点击链路（AppleScript / NSWorkspace.open）
// 本身都完整跑通了，唯一残余问题是宿主 app 是 LSUIElement（菜单栏常驻、无 Dock 图标），
// 平时不持有"激活令牌"；AppleScript 里的 activate 在这种情况下会被系统焦点窃取防护
// 拦下，Mail 窗口开在后台，用户在屏幕上完全看不见。点击这一刻宿主 app 恰好被系统提到
// 前台、短暂持有激活令牌，这时用 AppKit 原生 NSRunningApplication.activate() 去激活
// Mail 是合法有效的，所以在现有逻辑之外都补了一发原生激活（Mail 没在运行时跳过，
// 交给各自现有逻辑——AppleScript 的 activate/NSWorkspace.open——去拉起它）。

import Foundation
#if canImport(AppKit)
import AppKit
#endif

enum MailAppOpener {

    /// 打开某一封邮件。`messageIdHeader` 不含尖括号（和 MessageSummary.messageIdHeader
    /// 的约定一致），这里负责补回 `<...>` 并做 message:// URL 编码。
    @discardableResult
    static func openMessage(messageIdHeader: String) -> Bool {
        let trimmed = messageIdHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let url = URL(string: "message://%3C\(trimmed)%3E") else { return false }
        #if canImport(AppKit)
        let opened = NSWorkspace.shared.open(url)
        // Mail 若还没在跑，open 会把它拉起来，但那需要一点时间——原生 activate 立刻发
        // 没意义（NSRunningApplication 还找不到它），所以延后 0.5s 再补一发，把它提到前台。
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            activateMailIfRunning()
        }
        return opened
        #else
        return false
        #endif
    }

    /// activate Mail.app，并尽力把它切到指定账户的收件箱。`accountName` 为 nil 或者
    /// 在 Mail 里匹配不到同名账户，就静默降级成"只 activate"（不报错、不弹提示）。
    static func openMailbox(accountName: String?) {
        #if canImport(AppKit)
        // 点击这一刻宿主 app（LSUIElement）被系统短暂提到前台、持有激活令牌，用它原生
        // activate Mail：Mail 没在运行就跳过，交给下面 AppleScript 自己的 activate 拉起。
        activateMailIfRunning()
        DispatchQueue.global(qos: .userInitiated).async {
            guard let script = NSAppleScript(source: scriptSource(accountName: accountName)) else {
                // NSAppleScript 建不出来就退化成最基础的"打开 Mail.app"。
                NSWorkspace.shared.open(
                    URL(fileURLWithPath: "/System/Applications/Mail.app")
                )
                return
            }
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            // 这里不上抛/不重试：activate 本身在脚本里最前面且没包在 try 里，
            // 只有"选中指定邮箱"那段失败时才会走到 AppleScript 的 on error，
            // 静默丢弃即可（同函数签名要求：无返回值、不 throw）。
        }
        #endif
    }

    #if canImport(AppKit)
    /// Mail 已经在跑就原生激活它；没在跑就什么都不做（交给调用方各自的拉起逻辑）。
    /// 用无参 `activate()`——`activate(options: [.activateIgnoringOtherApps])` 在
    /// macOS 14 标记 deprecated（ignoringOtherApps 不再有效果），无参版本是新推荐写法。
    private static func activateMailIfRunning() {
        guard let mail = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first else {
            return
        }
        mail.activate()
    }
    #endif

    /// accountName 为 nil 时只 activate；否则额外尝试 `account "<name>"` 匹配并选中其收件箱，
    /// 失败（账户改名了/没这个账户/没有打开的邮件查看窗口）就在 AppleScript 内部吞掉。
    ///
    /// P0 修复记录（返工 1）：Mail 的 AppleScript 字典里没有 "mail viewer" 这个类，
    /// osacompile 实测直接编译失败（"Expected given/with/without... but found identifier"）；
    /// 正确类名是 **message viewer**（`count of message viewers` / `message viewer 1`）。
    /// 顺手加固：收件箱名字有的账户是 "INBOX" 有的是 "Inbox"，内层 try/on error 两个都试。
    ///
    /// P0 修复记录（返工 2，AE 明文跟踪实锤）：脚本本身跑得完整没错，但 Mail 冷启动/
    /// 被用户关掉所有窗口时 `message viewers` 为 0，`activate` 一个没有任何窗口的 app
    /// 在屏幕上没有任何视觉变化，用户会以为"点了没反应"。修法：activate 之后如果
    /// `message viewers` 是 0，先 `reopen`（等价于点 Dock 图标，让 Mail 弹出默认主窗口，
    /// 比手动 make new message viewer 更贴近系统原生行为）再继续；nil 分支（只 activate，
    /// 对应"All Inboxes"总览）同样补这一步，保证点击后 Mail 一定有窗口冒出来。
    static func scriptSource(accountName: String?) -> String {
        guard let accountName, !accountName.isEmpty else {
            return """
            tell application "Mail"
                activate
                if (count of message viewers) is 0 then
                    reopen
                end if
            end tell
            """
        }
        let escaped = Self.escapeForAppleScriptLiteral(accountName)
        return """
        tell application "Mail"
            activate
            if (count of message viewers) is 0 then
                reopen
            end if
            try
                set targetAccount to account "\(escaped)"
                try
                    set targetMailbox to mailbox "INBOX" of targetAccount
                on error
                    set targetMailbox to mailbox "Inbox" of targetAccount
                end try
                if (count of message viewers) > 0 then
                    set selected mailboxes of message viewer 1 to {targetMailbox}
                end if
            end try
        end tell
        """
    }

    /// 把 name 里的反斜杠/双引号转义成安全的 AppleScript 字符串字面量内容。
    static func escapeForAppleScriptLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 契约 11 — 一键"全部已读"的真标记（对应 `SnapshotStore.applyLocalMarkAllRead`
    /// 那边的乐观清零）。`accountNames` 为 nil 时对每个账户都做；否则只对列出的账户名
    /// 逐个做。每个账户内部用 `set read status of every message of targetMailbox to
    /// true` 一条 Apple Event 让 Mail 内部批量执行，不是我们这边逐封邮件发一次 AE
    /// （性能同 openMailbox 的原则：批量优于循环调用）。
    ///
    /// 这是纯后台动作：不 activate、不 reopen——用户点的是"全部已读"，不代表想看到
    /// Mail 窗口跳出来抢焦点。大邮箱（几千封未读，本机就有账户是这个量级）Mail 可能
    /// 要在后台忙一阵子才处理完，这是预期行为，不是卡住。
    static func markAllRead(accountNames: [String]?) {
        #if canImport(AppKit)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let script = NSAppleScript(source: markAllReadScriptSource(accountNames: accountNames)) else {
                return
            }
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            // 静默丢弃：每个账户内部已经包了自己的 try，这里没有更多能做的；
            // 函数签名本来就无返回值、不 throw。
        }
        #endif
    }

    /// `markAllRead` 用的 AppleScript 源。收件箱名字兼容 "INBOX"/"Inbox"，跟
    /// `scriptSource(accountName:)` 里的双兜底一致。非 private 是为了让 harness/单测
    /// 能直接 dump 出来喂给 osacompile 验证语法，不用真执行（会弹自动化权限框）。
    static func markAllReadScriptSource(accountNames: [String]?) -> String {
        guard let accountNames, !accountNames.isEmpty else {
            return """
            tell application "Mail"
                repeat with targetAccount in every account
                    try
                        set targetMailbox to missing value
                        try
                            set targetMailbox to mailbox "INBOX" of targetAccount
                        on error
                            set targetMailbox to mailbox "Inbox" of targetAccount
                        end try
                        set read status of every message of targetMailbox to true
                    end try
                end repeat
            end tell
            """
        }
        let literalList = accountNames
            .map { "\"\(Self.escapeForAppleScriptLiteral($0))\"" }
            .joined(separator: ", ")
        return """
        tell application "Mail"
            repeat with acctName in {\(literalList)}
                try
                    set targetAccount to account acctName
                    set targetMailbox to missing value
                    try
                        set targetMailbox to mailbox "INBOX" of targetAccount
                    on error
                        set targetMailbox to mailbox "Inbox" of targetAccount
                    end try
                    set read status of every message of targetMailbox to true
                end try
            end repeat
        end tell
        """
    }
}
