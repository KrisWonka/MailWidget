// MailAccountProbeTests.swift
// DataKitTests — Contract：`ProviderProbe.hasConfiguredMailAccounts()` 判断 Mail.app 里
// 有没有配置真实邮件账户（不含本地 Drafts/Outbox 这类伪邮箱）。
//
// 真机部署实录：朋友的 Mail.app 一个真实账户都没有，收件箱/日报全是空的，却没有任何
// 提示告诉他原因。这里只测 `containsRemoteMailbox(urls:)` 这个纯判定——它是 local://
// 与 imap:// 之间判别的全部逻辑，不需要真的打开 Envelope Index 就能验证。

import XCTest
import Foundation

final class MailAccountProbeTests: XCTestCase {

    func testOnlyLocalMailboxesMeansNoRealAccount() {
        let urls = [
            "local://Drafts",
            "local://Outbox",
            "local://Junk",
        ]
        XCTAssertFalse(ProviderProbe.containsRemoteMailbox(urls: urls))
    }

    func testAnyImapMailboxCountsAsARealAccount() {
        let urls = [
            "local://Drafts",
            "imap://ABCDEF12-3456-7890-ABCD-EF1234567890/INBOX",
        ]
        XCTAssertTrue(ProviderProbe.containsRemoteMailbox(urls: urls))
    }

    func testOtherRemoteSchemesAlsoCount() {
        XCTAssertTrue(ProviderProbe.containsRemoteMailbox(urls: ["ews://account/INBOX"]))
        XCTAssertTrue(ProviderProbe.containsRemoteMailbox(urls: ["pop://account/INBOX"]))
    }

    func testEmptyMailboxListMeansNoRealAccount() {
        XCTAssertFalse(ProviderProbe.containsRemoteMailbox(urls: []))
    }

    func testMalformedURLWithoutSchemeIsIgnoredNotCountedAsRemote() {
        // 没有 "://" 的字符串不是一个合法的 mailbox URL——保守起见不当远程账户算。
        XCTAssertFalse(ProviderProbe.containsRemoteMailbox(urls: ["not-a-url"]))
    }

    func testUnreadableMailDirectoryFailsOpenAsTrueNotFalse() {
        // 指向一个根本不存在 V*/MailData 结构的目录：`mailboxURLs` 会 throw，
        // `hasConfiguredMailAccounts(mailDirectory:)` 必须"不确定时不误报"，返回 true，
        // 而不是把"读不到"悄悄当成"没有账户"。
        let bogusDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MailAccountProbeTests-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(ProviderProbe.hasConfiguredMailAccounts(mailDirectory: bogusDirectory))
    }
}
