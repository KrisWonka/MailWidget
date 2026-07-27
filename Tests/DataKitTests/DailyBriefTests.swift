import Foundation
import XCTest

/// DailyBrief 把日报载荷和本地收件箱快照按 Message-ID 关联起来。关联结果直接决定
/// 右上角那个未读数准不准、以及每一份下面能不能显示真实邮件行。
final class DailyBriefTests: XCTestCase {

    // MARK: - 构造样本

    fileprivate func message(
        id: String, header: String?, isRead: Bool, subject: String = "Subject"
    ) -> MessageSummary {
        MessageSummary(
            id: id, messageIdHeader: header, sender: "Sender", senderEmail: "s@example.com",
            subject: subject, snippet: "", date: Date(), isRead: isRead, isFlagged: false
        )
    }

    fileprivate func snapshot(_ messages: [MessageSummary], accountID: String = "acct-1") -> MailSnapshot {
        MailSnapshot(
            generatedAt: Date(), providerKind: "envelopeIndex",
            accounts: [AccountSummary(
                id: accountID, name: "Test", email: DailySummaryConstants.expectedMailbox,
                mailboxes: [MailboxSummary(id: "mb", name: "Inbox", role: "inbox",
                                           unreadCount: 0, messages: messages)]
            )]
        )
    }

    fileprivate func item(id: String, header: String?) -> DailySummaryItem {
        DailySummaryItem(
            id: id, level: .today, title: "标题", detail: "几行话总结",
            gmailURL: URL(string: "https://mail.google.com/mail/u/0/?authuser=krisxia%40umich.edu#all/\(id)")!,
            messageIdHeader: header
        )
    }

    fileprivate func summary(_ items: [DailySummaryItem], headline: String = "今天有事") -> DailySummary {
        DailySummary(
            schemaVersion: 1, mailbox: DailySummaryConstants.expectedMailbox,
            generatedAt: "2026-07-27T09:03:24-04:00", headline: headline, items: items
        )
    }

    // MARK: -

    func testJoinsItemToMessageByMessageID() throws {
        let brief = try XCTUnwrap(DailyBrief.resolve(
            summary: summary([item(id: "t1", header: "abc@example.com")]),
            snapshot: snapshot([message(id: "m1", header: "abc@example.com", isRead: false,
                                        subject: "真实主题")])
        ))
        XCTAssertEqual(brief.items.count, 1)
        XCTAssertEqual(brief.items[0].message?.subject, "真实主题")
        XCTAssertEqual(brief.items[0].accountID, "acct-1")
    }

    /// Mail 本地没同步到这封信时 message 为 nil，视图据此退化 —— 不能崩、也不能乱认一封。
    func testUnmatchedItemHasNoMessage() throws {
        let brief = try XCTUnwrap(DailyBrief.resolve(
            summary: summary([item(id: "t1", header: "missing@example.com")]),
            snapshot: snapshot([message(id: "m1", header: "other@example.com", isRead: false)])
        ))
        XCTAssertNil(brief.items[0].message)
        XCTAssertNil(brief.items[0].accountID)
        XCTAssertFalse(brief.items[0].isUnread)
    }

    func testItemWithoutMessageIDNeverMatches() throws {
        let brief = try XCTUnwrap(DailyBrief.resolve(
            summary: summary([item(id: "t1", header: nil)]),
            snapshot: snapshot([message(id: "m1", header: "abc@example.com", isRead: false)])
        ))
        XCTAssertNil(brief.items[0].message)
    }

    /// 未读数只统计"确实关联到、且确实未读"的条目。关联不到的一律不计——
    /// 宁可少数，也不要让角标变成猜的。
    func testUnreadCountOnlyCountsMatchedUnreadItems() throws {
        let brief = try XCTUnwrap(DailyBrief.resolve(
            summary: summary([
                item(id: "t1", header: "a@x.com"),   // 关联到，未读
                item(id: "t2", header: "b@x.com"),   // 关联到，已读
                item(id: "t3", header: "c@x.com"),   // 关联不到
                item(id: "t4", header: nil),         // 没有 Message-ID
            ]),
            snapshot: snapshot([
                message(id: "m1", header: "a@x.com", isRead: false),
                message(id: "m2", header: "b@x.com", isRead: true),
            ])
        ))
        XCTAssertEqual(brief.unreadCount, 1)
    }

    func testNilSnapshotStillProducesBrief() throws {
        let brief = try XCTUnwrap(DailyBrief.resolve(
            summary: summary([item(id: "t1", header: "a@x.com")]), snapshot: nil
        ))
        XCTAssertEqual(brief.items.count, 1)
        XCTAssertNil(brief.items[0].message)
        XCTAssertEqual(brief.unreadCount, 0)
    }

    func testNilSummaryProducesNoBrief() {
        XCTAssertNil(DailyBrief.resolve(summary: nil, snapshot: snapshot([])))
    }

    // MARK: - 分页

    func testPaginationSlicesButKeepsTotalUnreadCount() throws {
        let items = (1...5).map { item(id: "t\($0)", header: "m\($0)@x.com") }
        let messages = (1...5).map { message(id: "m\($0)", header: "m\($0)@x.com", isRead: false) }
        let brief = try XCTUnwrap(DailyBrief.resolve(summary: summary(items), snapshot: snapshot(messages)))

        let paged = brief.paginated(pageSize: 3)
        XCTAssertEqual(paged.items.count, 3)
        XCTAssertEqual(paged.pageInfo?.totalPages, 2)
        // 角标是整份日报的总数，不随翻页缩水 —— 与 MailWidget 的 unreadCount 语义一致。
        XCTAssertEqual(paged.unreadCount, 5)
    }

    func testPaginationClampsOutOfRangePage() throws {
        let items = (1...2).map { item(id: "t\($0)", header: nil) }
        let brief = try XCTUnwrap(DailyBrief.resolve(summary: summary(items), snapshot: nil))

        let defaults = UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
        let key = PageState.key(forScopeID: DailyBrief.scopeID)
        let previous = defaults?.object(forKey: key)
        defer {
            if let previous { defaults?.set(previous, forKey: key) } else { defaults?.removeObject(forKey: key) }
        }

        defaults?.set(99, forKey: key)
        let paged = brief.paginated(pageSize: 1)
        XCTAssertEqual(paged.pageInfo?.currentPage, 1, "越界页号必须夹回最后一页")
        XCTAssertEqual(paged.items.count, 1)
    }

    func testEmptyItemsPaginateSafely() throws {
        let brief = try XCTUnwrap(DailyBrief.resolve(summary: summary([]), snapshot: nil))
        let paged = brief.paginated(pageSize: 3)
        XCTAssertTrue(paged.items.isEmpty)
        XCTAssertNil(paged.pageInfo)
    }
}

/// 早先版本拿"快照命中"当作能否跳转的前提，把本来能正确打开的邮件挡成了兜底：
/// 快照只索引 inbox 且每个最多 50 封，一封信不在窗口里 ≠ Mail 里没有它。
extension DailyBriefTests {
    func testMailURLDoesNotDependOnSnapshotMatch() throws {
        let header = "20260726160340.13cbcf6413d3d6b2@mail.joinhandshake.com"
        let brief = try XCTUnwrap(DailyBrief.resolve(
            summary: summary([item(id: "t1", header: header)]),
            snapshot: snapshot([])          // 快照里一封都没有
        ))
        let entry = brief.items[0]
        XCTAssertNil(entry.message, "确实没关联到")
        XCTAssertEqual(
            entry.mailURL?.absoluteString,
            "message://%3C\(header)%3E",
            "没关联到也必须能跳那封信"
        )
    }

    func testMailURLIsNilWithoutMessageID() throws {
        let brief = try XCTUnwrap(DailyBrief.resolve(
            summary: summary([item(id: "t1", header: nil)]), snapshot: nil
        ))
        XCTAssertNil(brief.items[0].mailURL)
    }
}
