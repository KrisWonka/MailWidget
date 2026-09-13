import Foundation
import XCTest

/// 邮箱去个人化之后，`DailySummaryConstants.expectedMailbox` 不再是编译期常量
/// `"you@example.com"`，而是读 App Group `userMailbox` 键的运行态值——大多数用例
/// 需要一个已知的、固定的邮箱才能断言"匹配 / 不匹配"，所以每个测试类都在 setUp 里
/// 显式配置这一个值，并在 tearDown 里还原成进入测试前的值（而不是无脑清空），
/// 这样测试不会因为运行顺序或复用同一个 UserDefaults suite 而互相影响，也不会
/// 冲掉这台机器上任何已经存在的真实配置。
private let testMailbox = "friend@example.com"

final class DailySummaryValidationTests: XCTestCase {
    private var previousConfiguredMailbox: String?

    override func setUpWithError() throws {
        previousConfiguredMailbox = DailySummaryConstants.configuredMailbox
        DailySummaryConstants.configuredMailbox = testMailbox
    }

    override func tearDownWithError() throws {
        DailySummaryConstants.configuredMailbox = previousConfiguredMailbox
    }

    func testValidSummaryPassesValidation() throws {
        XCTAssertNoThrow(try DailySummaryValidator.validate(makeSummary()))
    }

    func testEmptySummaryIsValid() throws {
        XCTAssertNoThrow(try DailySummaryValidator.validate(makeSummary(items: [])))
    }

    func testRejectsUnsupportedSchemaVersion() {
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(schemaVersion: 2))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .unsupportedSchemaVersion(2))
        }
    }

    func testRejectsWrongMailbox() {
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(mailbox: "other@example.com"))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .unexpectedMailbox("other@example.com"))
        }
    }

    func testRejectsMoreThanSixItems() {
        let items = (0...6).map { makeItem(id: "item-\($0)") }
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: items))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .tooManyItems(7))
        }
    }

    func testRejectsNonHTTPSURL() {
        let item = makeItem(
            url: "http://mail.google.com/mail/u/0/?authuser=friend%40example.com#all/message-1"
        )
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: [item]))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .invalidGmailURL(item.id))
        }
    }

    func testRejectsLookalikeGmailHost() {
        let item = makeItem(
            url: "https://mail.google.com.example.org/mail/u/0/?authuser=friend%40example.com#all/message-1"
        )
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: [item]))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .invalidGmailURL(item.id))
        }
    }

    func testRejectsInboxRoute() {
        let item = makeItem(
            url: "https://mail.google.com/mail/u/0/?authuser=friend%40example.com#inbox/message-1"
        )
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: [item]))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .invalidGmailURL(item.id))
        }
    }

    func testRejectsWrongAuthUser() {
        let item = makeItem(
            url: "https://mail.google.com/mail/u/0/?authuser=other%40example.com#all/message-1"
        )
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: [item]))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .invalidGmailURL(item.id))
        }
    }

    func testRejectsMissingAuthUser() {
        let item = makeItem(url: "https://mail.google.com/mail/u/0/#all/message-1")
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: [item]))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .invalidGmailURL(item.id))
        }
    }

    func testRejectsWrongMailboxPath() {
        let item = makeItem(
            url: "https://mail.google.com/mail/u/1/?authuser=friend%40example.com#all/message-1"
        )
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: [item]))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .invalidGmailURL(item.id))
        }
    }

    func testRejectsMismatchedMessageID() {
        let item = makeItem(
            id: "message-1",
            url: "https://mail.google.com/mail/u/0/?authuser=friend%40example.com#all/message-2"
        )
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: [item]))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .invalidGmailURL(item.id))
        }
    }

    func testRejectsDuplicateIDs() {
        let items = [makeItem(id: "same"), makeItem(id: "same")]
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: items))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .duplicateItemID("same"))
        }
    }
}

final class DailySummaryStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var previousConfiguredMailbox: String?

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        previousConfiguredMailbox = DailySummaryConstants.configuredMailbox
        DailySummaryConstants.configuredMailbox = testMailbox
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        DailySummaryConstants.configuredMailbox = previousConfiguredMailbox
    }

    func testSaveAndLoadRoundTrip() throws {
        let store = DailySummaryStore(containerURL: temporaryDirectory)
        let summary = makeSummary()

        try store.save(summary)

        XCTAssertEqual(try store.load(), summary)
    }

    func testRejectedUpdatePreservesPreviousSummary() throws {
        let store = DailySummaryStore(containerURL: temporaryDirectory)
        let previous = makeSummary(headline: "原来的日报")
        try store.save(previous)

        let invalid = makeSummary(mailbox: "wrong@example.com", headline: "不应覆盖")
        XCTAssertThrowsError(try store.save(invalid))

        XCTAssertEqual(try store.load(), previous)
    }

    func testLoadRejectsCorruptedFile() throws {
        let store = DailySummaryStore(containerURL: temporaryDirectory)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: store.summaryURL)

        XCTAssertThrowsError(try store.load())
    }
}

private func makeSummary(
    schemaVersion: Int = 1,
    mailbox: String = DailySummaryConstants.expectedMailbox,
    headline: String = "今天有 1 件事",
    items: [DailySummaryItem] = [makeItem()]
) -> DailySummary {
    DailySummary(
        schemaVersion: schemaVersion,
        mailbox: mailbox,
        generatedAt: "2026-07-19T14:00:00Z",
        headline: headline,
        items: items
    )
}

private func makeItem(
    id: String = "message-1",
    url: String? = nil
) -> DailySummaryItem {
    let resolvedURL = url ?? "https://mail.google.com/mail/u/0/?authuser=friend%40example.com#all/\(id)"
    return DailySummaryItem(
        id: id,
        level: .today,
        title: "需要确认的邮件",
        detail: "今天下班前回复",
        gmailURL: URL(string: resolvedURL)!
    )
}

/// `messageIdHeader` 是为"点日报直接进 Mail.app"加的可选字段。它必须能安全地拼进
/// `message://%3C…%3E`，也必须在缺省时保持向后兼容——老的日报载荷不带这个字段。
final class DailySummaryMessageIDTests: XCTestCase {
    private let validHeader = "20260726160340.13cbcf6413d3d6b2@mail.joinhandshake.com"
    private var previousConfiguredMailbox: String?

    override func setUpWithError() throws {
        previousConfiguredMailbox = DailySummaryConstants.configuredMailbox
        DailySummaryConstants.configuredMailbox = testMailbox
    }

    override func tearDownWithError() throws {
        DailySummaryConstants.configuredMailbox = previousConfiguredMailbox
    }

    func testValidMessageIDPasses() {
        XCTAssertNoThrow(
            try DailySummaryValidator.validate(
                makeSummary(items: [makeItem(messageIdHeader: validHeader)])
            )
        )
    }

    func testAbsentMessageIDIsValid() {
        XCTAssertNoThrow(try DailySummaryValidator.validate(makeSummary()))
        XCTAssertNil(makeItem().messageIdHeader)
    }

    /// 尖括号由 MailDeepLink 自己补，带进来会变成双层，深链直接失效。
    func testRejectsAngleBrackets() {
        for value in ["<\(validHeader)", "\(validHeader)>", "<\(validHeader)>"] {
            let item = makeItem(messageIdHeader: value)
            XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: [item]))) {
                XCTAssertEqual($0 as? DailySummaryValidationError, .invalidMessageID(item.id))
            }
        }
    }

    func testRejectsWhitespaceAndEmpty() {
        for value in ["", "   ", " \(validHeader)", "\(validHeader) ", "a b@c.com", "a\nb@c.com"] {
            let item = makeItem(messageIdHeader: value)
            XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: [item]))) {
                XCTAssertEqual($0 as? DailySummaryValidationError, .invalidMessageID(item.id))
            }
        }
    }

    func testRejectsOverlongMessageID() {
        let item = makeItem(messageIdHeader: String(repeating: "a", count: 999) + "@x.com")
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: [item]))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .invalidMessageID(item.id))
        }
    }

    func testRoundTripPreservesMessageID() throws {
        let summary = makeSummary(items: [makeItem(messageIdHeader: validHeader)])
        let decoded = try DailySummaryCodec.decode(DailySummaryCodec.encode(summary))
        XCTAssertEqual(decoded.items.first?.messageIdHeader, validHeader)
        XCTAssertEqual(decoded, summary)
    }

    /// 向后兼容：合并前产出的 JSON 里没有这个键，必须照常解出来且为 nil。
    func testDecodesLegacyPayloadWithoutMessageID() throws {
        let json = """
        {
          "schemaVersion": 1,
          "mailbox": "\(DailySummaryConstants.expectedMailbox)",
          "generatedAt": "2026-07-19T14:00:00Z",
          "headline": "今天有 1 件事",
          "items": [
            {
              "id": "message-1",
              "level": "today",
              "title": "需要确认的邮件",
              "detail": "今天下班前回复",
              "gmailURL": "https://mail.google.com/mail/u/0/?authuser=friend%40example.com#all/message-1"
            }
          ]
        }
        """
        let decoded = try DailySummaryCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded.items.count, 1)
        XCTAssertNil(decoded.items[0].messageIdHeader)
    }

    /// 缺省的 nil 不应该被编码成 "messageIdHeader": null，否则消费方要多处理一种形态。
    func testNilMessageIDIsOmittedFromEncoding() throws {
        let data = try DailySummaryCodec.encode(makeSummary())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("messageIdHeader"))
    }
}

private func makeItem(
    id: String = "message-1",
    url: String? = nil,
    messageIdHeader: String?
) -> DailySummaryItem {
    let resolvedURL = url ?? "https://mail.google.com/mail/u/0/?authuser=friend%40example.com#all/\(id)"
    return DailySummaryItem(
        id: id,
        level: .today,
        title: "需要确认的邮件",
        detail: "今天下班前回复",
        gmailURL: URL(string: resolvedURL)!,
        messageIdHeader: messageIdHeader
    )
}

/// 去个人化改造新增：邮箱不再是编译期常量，而是"首份载荷自动认领、之后按配置值
/// 硬性校验"。这两条用例直接对应那句设计——(a) 未配置时放行且自动认领，
/// (b) 已配置且不一致时仍然拒收——分开成专门的测试类，让这两条行为契约不会被
/// 淹没在一堆别的邮箱断言里。
final class DailySummaryMailboxConfigurationTests: XCTestCase {
    private var previousConfiguredMailbox: String?

    override func setUpWithError() throws {
        previousConfiguredMailbox = DailySummaryConstants.configuredMailbox
        DailySummaryConstants.configuredMailbox = nil
    }

    override func tearDownWithError() throws {
        DailySummaryConstants.configuredMailbox = previousConfiguredMailbox
    }

    /// 没有配置邮箱时：校验放行，且把这份载荷的 mailbox 写回配置——这就是"首次
    /// 投递自动认领"，克隆仓库的人不需要先去设置里填一遍自己的邮箱。
    func testUnconfiguredMailboxIsClaimedFromFirstPayload() throws {
        XCTAssertNil(DailySummaryConstants.configuredMailbox, "前置条件：还没配置")

        let summary = makeSummary(mailbox: "newcomer@example.com", items: [])
        XCTAssertNoThrow(try DailySummaryValidator.validate(summary))

        XCTAssertEqual(
            DailySummaryConstants.configuredMailbox, "newcomer@example.com",
            "首次投递之后应当自动认领为配置值"
        )
    }

    /// 已经配置过邮箱之后：不一致的载荷仍然被拒收，不会被第二次"认领"覆盖掉。
    func testConfiguredMailboxStillRejectsMismatch() throws {
        DailySummaryConstants.configuredMailbox = "owner@example.com"

        let summary = makeSummary(mailbox: "intruder@example.com", items: [])
        XCTAssertThrowsError(try DailySummaryValidator.validate(summary)) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .unexpectedMailbox("intruder@example.com"))
        }

        XCTAssertEqual(
            DailySummaryConstants.configuredMailbox, "owner@example.com",
            "被拒收的载荷不能悄悄改写已有配置"
        )
    }
}
