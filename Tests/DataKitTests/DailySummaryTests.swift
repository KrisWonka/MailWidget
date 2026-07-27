import Foundation
import XCTest

final class DailySummaryValidationTests: XCTestCase {
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
            url: "http://mail.google.com/mail/u/0/?authuser=krisxia%40umich.edu#all/message-1"
        )
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: [item]))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .invalidGmailURL(item.id))
        }
    }

    func testRejectsLookalikeGmailHost() {
        let item = makeItem(
            url: "https://mail.google.com.example.org/mail/u/0/?authuser=krisxia%40umich.edu#all/message-1"
        )
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: [item]))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .invalidGmailURL(item.id))
        }
    }

    func testRejectsInboxRoute() {
        let item = makeItem(
            url: "https://mail.google.com/mail/u/0/?authuser=krisxia%40umich.edu#inbox/message-1"
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
            url: "https://mail.google.com/mail/u/1/?authuser=krisxia%40umich.edu#all/message-1"
        )
        XCTAssertThrowsError(try DailySummaryValidator.validate(makeSummary(items: [item]))) {
            XCTAssertEqual($0 as? DailySummaryValidationError, .invalidGmailURL(item.id))
        }
    }

    func testRejectsMismatchedMessageID() {
        let item = makeItem(
            id: "message-1",
            url: "https://mail.google.com/mail/u/0/?authuser=krisxia%40umich.edu#all/message-2"
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

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
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
    let resolvedURL = url ?? "https://mail.google.com/mail/u/0/?authuser=krisxia%40umich.edu#all/\(id)"
    return DailySummaryItem(
        id: id,
        level: .today,
        title: "需要确认的邮件",
        detail: "今天下班前回复",
        gmailURL: URL(string: resolvedURL)!
    )
}
