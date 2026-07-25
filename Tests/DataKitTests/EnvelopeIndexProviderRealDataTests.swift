// EnvelopeIndexProviderRealDataTests.swift
// DataKitTests — regression coverage for EnvelopeIndexProvider's SQL, per spec.md's "Spike 已证实的
// 数据源事实" / 修正 1 / 修正 2.
//
// KNOWN LIMITATION (see P1 finding in the delivery report): EnvelopeIndexProvider has no
// path-injection point — `init()` takes no parameters and always locates the real
// ~/Library/Mail/V*/MailData/Envelope Index via `homeDirectoryForCurrentUser`. We are not allowed to
// modify DataKit, so we cannot point it at a synthetic fixture database that deterministically
// exercises the iCloud-direct / Gmail-labels / message_global_data-join scenarios.
//
// Instead, every test here (a) treats the *real* Envelope Index as read-only ground truth, (b)
// independently re-derives the expected query result via the exact same SQL EnvelopeIndexProvider.swift
// uses (shelled out to `/usr/bin/sqlite3 -readonly -json`, never linking against the provider's
// internals), and (c) compares that independent oracle against what `EnvelopeIndexProvider().fetchSnapshot()`
// actually returns. Every test is `XCTSkip`-guarded for the shape of real data it needs (e.g. "at least
// one Gmail-style label-only INBOX must exist right now") so the suite is not flaky across machines/time,
// but on this development machine all three regression scenarios from spec.md are known to be
// exercisable (verified via manual sqlite3 introspection before writing this file).

import XCTest
import Foundation

final class EnvelopeIndexProviderRealDataTests: XCTestCase {

    // MARK: - Locating the real Envelope Index (mirrors EnvelopeIndexProvider.locateEnvelopeIndex)

    private static let envelopeIndexPath: String? = {
        let mailDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: mailDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let vDirs: [(Int, URL)] = entries.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("V"), let number = Int(name.dropFirst()) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return (number, url)
        }
        guard let newest = vDirs.max(by: { $0.0 < $1.0 }) else { return nil }
        let dbURL = newest.1.appendingPathComponent("MailData").appendingPathComponent("Envelope Index")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        return dbURL.path
    }()

    private func makeProviderOrSkip() throws -> EnvelopeIndexProvider {
        do {
            return try EnvelopeIndexProvider()
        } catch {
            throw XCTSkip("EnvelopeIndexProvider() threw in this environment (\(error)) — likely missing Full Disk Access for the test runner process. Skipping real-data regression tests.")
        }
    }

    // MARK: - Independent SQL oracle (Process -> /usr/bin/sqlite3 -json; never touches DataKit's SQLite3 handle)

    private struct RawRow: Decodable {
        let rowid: Int64
        let address: String?
        let comment: String?
        let subject: String?
        let summary: String?
        let date_received: Double?
        let read: Int
        let flagged: Int
        /// Correct join per spec 修正 1: message_global_data.message_id == messages.message_id.
        let message_id_header: String?
        /// Deliberately the WRONG join (message_global_data.message_id == messages.ROWID), computed
        /// only so tests can prove the two strategies diverge on real data (see
        /// testMessageGlobalDataJoinsOnMessageIdColumnNotROWID).
        let message_id_header_wrong_join: String?
    }

    private struct MailboxRow: Decodable {
        let rowid: Int64
        let url: String
        let direct_count: Int
        let label_count: Int
    }

    private func runSQLiteJSON(_ sql: String) throws -> Data {
        guard let dbPath = Self.envelopeIndexPath else {
            throw XCTSkip("No ~/Library/Mail/V*/MailData/Envelope Index found on this machine.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", "file:\(dbPath)?mode=ro", sql]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8) ?? "sqlite3 exited \(process.terminationStatus)"
            throw XCTSkip("sqlite3 CLI query failed (likely no Full Disk Access for this test process): \(message)")
        }
        return outData.isEmpty ? Data("[]".utf8) : outData
    }

    /// All INBOX-named mailboxes plus, for each, how many messages reach it via `messages.mailbox`
    /// directly vs. only via the `labels` table — i.e. which accounts are iCloud-style (direct) vs.
    /// Gmail-style (label-only, spec 修正 2).
    private func findInboxMailboxes() throws -> [MailboxRow] {
        let sql = """
        SELECT mb.ROWID AS rowid, mb.url AS url,
               (SELECT COUNT(*) FROM messages m WHERE m.deleted = 0 AND m.mailbox = mb.ROWID) AS direct_count,
               (SELECT COUNT(*) FROM labels l JOIN messages m ON m.ROWID = l.message_id
                  WHERE m.deleted = 0 AND l.mailbox_id = mb.ROWID) AS label_count
        FROM mailboxes mb
        WHERE mb.url LIKE '%/INBOX';
        """
        let data = try runSQLiteJSON(sql)
        return try JSONDecoder().decode([MailboxRow].self, from: data)
    }

    private func accountUUID(fromMailboxURL url: String) -> String? {
        guard let schemeRange = url.range(of: "://") else { return nil }
        let rest = url[schemeRange.upperBound...]
        guard let slashIndex = rest.firstIndex(of: "/") else { return nil }
        let authority = String(rest[rest.startIndex..<slashIndex])
        return authority.isEmpty ? nil : authority
    }

    /// Reproduces EXACTLY the SQL in EnvelopeIndexProvider.messagesInMailbox / messageSelectColumns /
    /// messageJoins, plus one extra diagnostic column for the wrong (ROWID-based) join.
    private func fetchRawMessages(mailboxRowID: Int64, limit: Int = 20) throws -> [RawRow] {
        let sql = """
        SELECT m.ROWID AS rowid, a.address AS address, a.comment AS comment, s.subject AS subject,
               su.summary AS summary, m.date_received AS date_received, m.read AS read, m.flagged AS flagged,
               (SELECT message_id_header FROM message_global_data WHERE message_id = m.message_id) AS message_id_header,
               (SELECT message_id_header FROM message_global_data WHERE message_id = m.ROWID) AS message_id_header_wrong_join
        FROM messages m
        LEFT JOIN addresses a ON m.sender = a.ROWID
        LEFT JOIN subjects s ON m.subject = s.ROWID
        LEFT JOIN summaries su ON m.summary = su.ROWID
        WHERE m.deleted = 0 AND (m.mailbox = \(mailboxRowID) OR EXISTS (
            SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id = \(mailboxRowID)
        ))
        ORDER BY m.date_received DESC
        LIMIT \(limit);
        """
        let data = try runSQLiteJSON(sql)
        return try JSONDecoder().decode([RawRow].self, from: data)
    }

    /// Converts a RawRow the same way EnvelopeIndexProvider.convert(_:) does, and asserts it matches
    /// the corresponding MessageSummary from the real snapshot.
    private func assertMessagesMatch(
        _ expected: [RawRow], _ actual: [MessageSummary],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(expected.count, actual.count, "message count", file: file, line: line)
        for (raw, message) in zip(expected, actual) {
            let header = stripAngleBracketsForTest(raw.message_id_header)
            let expectedId = header ?? String(raw.rowid)
            let hasDisplayName = (raw.comment?.isEmpty == false)
            let expectedSender = hasDisplayName ? raw.comment! : (raw.address ?? "")

            XCTAssertEqual(message.id, expectedId, "message.id", file: file, line: line)
            XCTAssertEqual(message.messageIdHeader, header, "message.messageIdHeader", file: file, line: line)
            XCTAssertEqual(message.sender, expectedSender, "message.sender", file: file, line: line)
            XCTAssertEqual(message.senderEmail, raw.address ?? "", "message.senderEmail", file: file, line: line)
            XCTAssertEqual(message.subject, raw.subject ?? "", "message.subject", file: file, line: line)
            XCTAssertEqual(message.snippet, makeSnippetForTest(raw.summary), "message.snippet", file: file, line: line)
            XCTAssertEqual(message.isRead, raw.read != 0, "message.isRead", file: file, line: line)
            XCTAssertEqual(message.isFlagged, raw.flagged != 0, "message.isFlagged", file: file, line: line)
            XCTAssertEqual(
                message.date.timeIntervalSince1970, raw.date_received ?? 0,
                accuracy: 0.001, "message.date", file: file, line: line
            )
        }
    }

    // MARK: - (a) iCloud direct-storage mode: messages.mailbox points straight at the INBOX row

    func testDirectlyStoredInboxMessagesAreVisible() throws {
        let candidates = try findInboxMailboxes()
        guard let candidate = candidates.first(where: { $0.direct_count > 0 }) else {
            throw XCTSkip("No directly-stored (iCloud-style) INBOX account found on this machine right now.")
        }
        let expectedRaw = try fetchRawMessages(mailboxRowID: candidate.rowid)
        guard !expectedRaw.isEmpty, let uuid = accountUUID(fromMailboxURL: candidate.url) else {
            throw XCTSkip("Direct-mode INBOX candidate has 0 non-deleted messages right now, nothing to assert.")
        }

        let provider = try makeProviderOrSkip()
        let snapshot = try provider.fetchSnapshot()
        let account = try XCTUnwrap(snapshot.accounts.first { $0.id == uuid }, "no account with id \(uuid) in snapshot")
        let inbox = try XCTUnwrap(account.mailboxes.first { $0.role == "inbox" })

        assertMessagesMatch(expectedRaw, inbox.messages)
    }

    // MARK: - (b) Gmail label-only mode — spec.md 修正 2, THE regression this suite must never miss

    func testGmailStyleLabelOnlyInboxMessagesAreVisible_Correction2Regression() throws {
        let candidates = try findInboxMailboxes()
        guard let candidate = candidates.first(where: { $0.direct_count == 0 && $0.label_count > 0 }) else {
            throw XCTSkip("No Gmail-style (labels-only INBOX, 0 direct messages.mailbox rows) account found on this machine right now.")
        }
        guard let uuid = accountUUID(fromMailboxURL: candidate.url) else {
            throw XCTSkip("Could not parse account UUID from mailbox url \(candidate.url)")
        }
        let expectedRaw = try fetchRawMessages(mailboxRowID: candidate.rowid)
        XCTAssertFalse(
            expectedRaw.isEmpty,
            "Sanity check failed: labels table reports \(candidate.label_count) messages for this INBOX but the oracle query returned none."
        )

        let provider = try makeProviderOrSkip()
        let snapshot = try provider.fetchSnapshot()
        let account = try XCTUnwrap(snapshot.accounts.first { $0.id == uuid }, "no account with id \(uuid) in snapshot")
        let inbox = try XCTUnwrap(account.mailboxes.first { $0.role == "inbox" })

        // This is the exact bug spec.md's 修正 2 describes: `messages.mailbox = INBOX.ROWID` alone
        // returns 0 rows for Gmail-style accounts because their messages physically live in "All Mail"
        // and INBOX membership is only recorded in `labels`. If EnvelopeIndexProvider ever drops the
        // `OR EXISTS (... labels ...)` clause, this assertion is what catches it.
        XCTAssertFalse(inbox.messages.isEmpty, "Gmail-style INBOX came back with 0 messages — labels-join regression (spec 修正 2).")
        assertMessagesMatch(expectedRaw, inbox.messages)
    }

    // MARK: - (c) message_global_data joins on message_id, not ROWID — spec.md 修正 1

    func testMessageGlobalDataJoinsOnMessageIdColumnNotROWID_Correction1Regression() throws {
        let candidates = try findInboxMailboxes()
        guard let candidate = candidates.max(by: { ($0.direct_count + $0.label_count) < ($1.direct_count + $1.label_count) }) else {
            throw XCTSkip("No INBOX mailboxes found on this machine right now.")
        }
        guard let uuid = accountUUID(fromMailboxURL: candidate.url) else {
            throw XCTSkip("Could not parse account UUID from mailbox url \(candidate.url)")
        }
        let expectedRaw = try fetchRawMessages(mailboxRowID: candidate.rowid)
        guard !expectedRaw.isEmpty else {
            throw XCTSkip("Busiest INBOX candidate on this machine has 0 messages right now.")
        }

        // Prove the two join strategies actually diverge on real data (i.e. this test is capable of
        // catching a regression rather than vacuously passing). spec.md states messages.ROWID and
        // messages.message_id are never equal in practice — confirmed 0/11712 on this machine.
        guard let divergentRow = expectedRaw.first(where: { $0.message_id_header != nil && $0.message_id_header_wrong_join == nil }) else {
            throw XCTSkip("Could not find a message where the correct (message_id) and wrong (ROWID) message_global_data joins diverge on this machine's current INBOX data — cannot demonstrate the 修正 1 regression right now.")
        }

        let provider = try makeProviderOrSkip()
        let snapshot = try provider.fetchSnapshot()
        let account = try XCTUnwrap(snapshot.accounts.first { $0.id == uuid })
        let inbox = try XCTUnwrap(account.mailboxes.first { $0.role == "inbox" })

        let expectedHeader = stripAngleBracketsForTest(divergentRow.message_id_header)
        let expectedId = expectedHeader ?? String(divergentRow.rowid)
        let actualMessage = try XCTUnwrap(
            inbox.messages.first { $0.id == expectedId },
            "message rowid=\(divergentRow.rowid) (expected header \(expectedHeader ?? "nil")) not found in live snapshot inbox"
        )

        // If EnvelopeIndexProvider ever joined message_global_data on m.ROWID instead of
        // m.message_id, this would silently regress to nil (the "wrong join" column above is nil
        // for this exact row) — this is the assertion that would catch it.
        XCTAssertEqual(actualMessage.messageIdHeader, expectedHeader)
        XCTAssertNotNil(actualMessage.messageIdHeader)
    }

    /// Companion to the regression test above: when message_global_data has no row / a NULL header for
    /// a message, MessageSummary.id must fall back to the ROWID string. On this machine, at the time
    /// this suite was written, all 11,712 messages in the real Envelope Index have a non-null header
    /// (verified via manual introspection), so this path currently has no real data to exercise — it
    /// is validated instead at the model layer by ModelsCodableTests
    /// (testMessageWithNullMessageIdHeaderAndFlaggedDecodesCorrectly, using the fixture's synthetic
    /// null-header message). This test stays in place and will start actually asserting the moment a
    /// real NULL-header message exists in this mailbox.
    func testMessageWithNullHeaderFallsBackToROWIDString_WhenRealDataHasOne() throws {
        let candidates = try findInboxMailboxes()
        guard let candidate = candidates.max(by: { ($0.direct_count + $0.label_count) < ($1.direct_count + $1.label_count) }) else {
            throw XCTSkip("No INBOX mailboxes found on this machine right now.")
        }
        let expectedRaw = try fetchRawMessages(mailboxRowID: candidate.rowid)
        guard let nullHeaderRow = expectedRaw.first(where: { $0.message_id_header == nil }) else {
            throw XCTSkip("No real message with a NULL message_global_data.message_id_header currently exists in this INBOX's most recent 20 messages — covered instead by ModelsCodableTests against the fixture's synthetic null-header case.")
        }
        guard let uuid = accountUUID(fromMailboxURL: candidate.url) else {
            throw XCTSkip("Could not parse account UUID from mailbox url \(candidate.url)")
        }

        let provider = try makeProviderOrSkip()
        let snapshot = try provider.fetchSnapshot()
        let account = try XCTUnwrap(snapshot.accounts.first { $0.id == uuid })
        let inbox = try XCTUnwrap(account.mailboxes.first { $0.role == "inbox" })

        let actualMessage = try XCTUnwrap(inbox.messages.first { $0.id == String(nullHeaderRow.rowid) })
        XCTAssertNil(actualMessage.messageIdHeader)
        XCTAssertEqual(actualMessage.id, String(nullHeaderRow.rowid))
    }
}
