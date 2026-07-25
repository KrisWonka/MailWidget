// ModelsCodableTests.swift
// DataKitTests — Contract 1 (Models.swift): MailSnapshot decodes losslessly from Fixtures/snapshot.fixture.json
// using the .iso8601 date strategy mandated by spec.md §4, and round-trips through encode/decode.

import XCTest
import Foundation

final class ModelsCodableTests: XCTestCase {

    /// Fixtures/ is intentionally NOT part of the DataKitTests target sources (project.yml only lists
    /// Tests/DataKitTests + DataKit), so there is no bundle resource to load. #filePath gives this
    /// source file's on-disk path at compile time; walk up from Tests/DataKitTests/<this file> to the
    /// repo root and back down into Fixtures/.
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/DataKitTests
            .deletingLastPathComponent() // .../Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Fixtures/snapshot.fixture.json")
    }

    /// `xcodebuild test`'s runner process on this machine has no Full Disk Access / Documents-folder
    /// TCC grant (verified: it also can't list ~/Library/Mail or read an existing App Group
    /// snapshot.json — see the P1 finding in the delivery report), so `Data(contentsOf: fixtureURL)`
    /// reliably returns nil here even though the exact same absolute path is trivially readable from a
    /// normal Terminal/shell. We still try the live file first (so this test picks up real edits to
    /// Fixtures/snapshot.fixture.json on any machine where the runner *does* have disk access, e.g. a
    /// properly-provisioned CI runner), and fall back to a byte-for-byte embedded copy otherwise so
    /// this — the most basic "does the model decode" test — isn't held hostage by that environment gap.
    private func loadFixtureData() throws -> Data {
        if let onDisk = try? Data(contentsOf: fixtureURL) {
            return onDisk
        }
        return Data(Self.embeddedFixtureJSONFallback.utf8)
    }

    /// Verbatim copy of Fixtures/snapshot.fixture.json as of 2026-07-22 (the day this test suite was
    /// written). If backend-dev/frontend-dev update the real fixture file, this fallback copy will go
    /// stale on machines where the live file is unreadable — the primary read path above always wins
    /// when available, so this only matters as a last resort. Keeping it in sync is a manual step;
    /// flagged as a coverage caveat in the delivery report.
    private static let embeddedFixtureJSONFallback = #"""
    {
      "generatedAt": "2026-07-22T12:00:00Z",
      "providerKind": "fixture",
      "accounts": [
        {
          "id": "3E6777FE-4C2B-4110-B304-25D8571E87EB",
          "name": "iCloud",
          "email": "kris@icloud.com",
          "mailboxes": [
            {
              "id": "imap://3E6777FE-4C2B-4110-B304-25D8571E87EB/INBOX",
              "name": "Inbox",
              "role": "inbox",
              "unreadCount": 3,
              "messages": [
                {
                  "id": "CAF1x9qq-demo-001@mail.example.com",
                  "messageIdHeader": "CAF1x9qq-demo-001@mail.example.com",
                  "sender": "Sarah Chen",
                  "senderEmail": "sarah.chen@example.com",
                  "subject": "Q3 planning doc — comments by Friday?",
                  "snippet": "Hi Kris, I just shared the Q3 planning doc with you. Could you leave comments by Friday so we can…",
                  "date": "2026-07-22T11:42:00Z",
                  "isRead": false,
                  "isFlagged": false
                },
                {
                  "id": "58213",
                  "messageIdHeader": null,
                  "sender": "GitHub",
                  "senderEmail": "notifications@github.com",
                  "subject": "[mail-widget] PR #12: Add extraLarge layout",
                  "snippet": "Merged #12 into main. 3 checks passed. View the pull request on GitHub or reply to this email to…",
                  "date": "2026-07-22T10:15:00Z",
                  "isRead": false,
                  "isFlagged": true
                },
                {
                  "id": "b2f4e-demo-003@newsletters.example.org",
                  "messageIdHeader": "b2f4e-demo-003@newsletters.example.org",
                  "sender": "Swift Weekly",
                  "senderEmail": "hello@newsletters.example.org",
                  "subject": "Issue #214: WidgetKit tips for macOS",
                  "snippet": "This week: containerBackground pitfalls, AppIntents configuration recipes, and a deep dive into…",
                  "date": "2026-07-22T08:03:00Z",
                  "isRead": false,
                  "isFlagged": false
                },
                {
                  "id": "9a887-demo-004@shop.example.com",
                  "messageIdHeader": "9a887-demo-004@shop.example.com",
                  "sender": "DigiKey",
                  "senderEmail": "order@shop.example.com",
                  "subject": "Your order has shipped",
                  "snippet": "Tracking number 1Z999AA10123456784. Estimated delivery Thursday. View or manage your order…",
                  "date": "2026-07-21T22:48:00Z",
                  "isRead": true,
                  "isFlagged": false
                }
              ]
            },
            {
              "id": "vip://3E6777FE-4C2B-4110-B304-25D8571E87EB",
              "name": "VIP",
              "role": "vip",
              "unreadCount": 1,
              "messages": [
                {
                  "id": "CAF1x9qq-demo-001@mail.example.com",
                  "messageIdHeader": "CAF1x9qq-demo-001@mail.example.com",
                  "sender": "Sarah Chen",
                  "senderEmail": "sarah.chen@example.com",
                  "subject": "Q3 planning doc — comments by Friday?",
                  "snippet": "Hi Kris, I just shared the Q3 planning doc with you. Could you leave comments by Friday so we can…",
                  "date": "2026-07-22T11:42:00Z",
                  "isRead": false,
                  "isFlagged": false
                }
              ]
            }
          ]
        },
        {
          "id": "7B01A2C4-1111-4222-8333-DEMO00000002",
          "name": "Gmail",
          "email": "wl2464649623@gmail.com",
          "mailboxes": [
            {
              "id": "imap://7B01A2C4-1111-4222-8333-DEMO00000002/INBOX",
              "name": "Inbox",
              "role": "inbox",
              "unreadCount": 1,
              "messages": [
                {
                  "id": "f00d-demo-005@ucimail.example.edu",
                  "messageIdHeader": "f00d-demo-005@ucimail.example.edu",
                  "sender": "Prof. McCarthy",
                  "senderEmail": "mccarthy@uci.example.edu",
                  "subject": "Meeting moved to 3pm Tuesday",
                  "snippet": "Kris — something came up Monday morning, can we move our meeting to Tuesday 3pm? Same office.…",
                  "date": "2026-07-22T09:30:00Z",
                  "isRead": false,
                  "isFlagged": false
                }
              ]
            }
          ]
        }
      ]
    }
    """#

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: - Decode + spot-check fields named in spec.md's test brief

    func testDecodeFixtureSucceeds() throws {
        let data = try loadFixtureData()
        let snapshot = try makeDecoder().decode(MailSnapshot.self, from: data)
        XCTAssertEqual(snapshot.providerKind, "fixture")
        XCTAssertEqual(snapshot.accounts.count, 2)
    }

    func testICloudAccountAndVIPPseudoMailboxDecodeCorrectly() throws {
        let data = try loadFixtureData()
        let snapshot = try makeDecoder().decode(MailSnapshot.self, from: data)

        let icloud = try XCTUnwrap(snapshot.accounts.first { $0.id == "3E6777FE-4C2B-4110-B304-25D8571E87EB" })
        XCTAssertEqual(icloud.name, "iCloud")
        XCTAssertEqual(icloud.email, "kris@icloud.com")
        XCTAssertEqual(icloud.mailboxes.count, 2)

        let inbox = try XCTUnwrap(icloud.mailboxes.first { $0.role == "inbox" })
        XCTAssertEqual(inbox.unreadCount, 3)
        XCTAssertEqual(inbox.messages.count, 4)

        let vip = try XCTUnwrap(icloud.mailboxes.first { $0.role == "vip" })
        XCTAssertEqual(vip.id, "vip://3E6777FE-4C2B-4110-B304-25D8571E87EB")
        XCTAssertEqual(vip.unreadCount, 1)
        XCTAssertEqual(vip.messages.count, 1)
        XCTAssertEqual(vip.messages[0].messageIdHeader, "CAF1x9qq-demo-001@mail.example.com")
        XCTAssertEqual(vip.messages[0].sender, "Sarah Chen")
    }

    /// The GitHub notification in the fixture is the one deliberately carrying
    /// `"messageIdHeader": null` (spike-verified real-world possibility) *and* `isFlagged: true` —
    /// exactly the two fields spec.md's test brief calls out to spot-check.
    func testMessageWithNullMessageIdHeaderAndFlaggedDecodesCorrectly() throws {
        let data = try loadFixtureData()
        let snapshot = try makeDecoder().decode(MailSnapshot.self, from: data)
        let icloud = try XCTUnwrap(snapshot.accounts.first { $0.id == "3E6777FE-4C2B-4110-B304-25D8571E87EB" })
        let inbox = try XCTUnwrap(icloud.mailboxes.first { $0.role == "inbox" })

        let githubMessage = try XCTUnwrap(inbox.messages.first { $0.id == "58213" })
        XCTAssertNil(githubMessage.messageIdHeader)
        XCTAssertTrue(githubMessage.isFlagged)
        XCTAssertFalse(githubMessage.isRead)
        XCTAssertEqual(githubMessage.sender, "GitHub")
        XCTAssertEqual(githubMessage.senderEmail, "notifications@github.com")
        XCTAssertEqual(githubMessage.subject, "[mail-widget] PR #12: Add extraLarge layout")
    }

    func testGmailAccountDecodesCorrectly() throws {
        let data = try loadFixtureData()
        let snapshot = try makeDecoder().decode(MailSnapshot.self, from: data)

        let gmail = try XCTUnwrap(snapshot.accounts.first { $0.id == "7B01A2C4-1111-4222-8333-DEMO00000002" })
        XCTAssertEqual(gmail.name, "Gmail")
        XCTAssertEqual(gmail.email, "wl2464649623@gmail.com")
        XCTAssertEqual(gmail.mailboxes.count, 1)

        let inbox = try XCTUnwrap(gmail.mailboxes.first { $0.role == "inbox" })
        XCTAssertEqual(inbox.unreadCount, 1)
        let message = try XCTUnwrap(inbox.messages.first)
        XCTAssertEqual(message.sender, "Prof. McCarthy")
        XCTAssertEqual(message.messageIdHeader, "f00d-demo-005@ucimail.example.edu")
    }

    func testGeneratedAtDecodesAsExpectedISO8601Instant() throws {
        let data = try loadFixtureData()
        let snapshot = try makeDecoder().decode(MailSnapshot.self, from: data)
        let expected = ISO8601DateFormatter().date(from: "2026-07-22T12:00:00Z")
        let expectedInterval = try XCTUnwrap(expected).timeIntervalSince1970
        XCTAssertEqual(snapshot.generatedAt.timeIntervalSince1970, expectedInterval, accuracy: 0.001)
    }

    // MARK: - Round trip

    func testEncodeDecodeRoundTripIsLossless() throws {
        let data = try loadFixtureData()
        let decoder = makeDecoder()
        let original = try decoder.decode(MailSnapshot.self, from: data)

        let reencoded = try makeEncoder().encode(original)
        let roundTripped = try decoder.decode(MailSnapshot.self, from: reencoded)

        assertSnapshotsEqual(original, roundTripped)
    }

    /// Round trip must also preserve a `nil` messageIdHeader as `nil` (not e.g. an empty string or a
    /// dropped key) — this is the one optional field in MessageSummary and the easiest to regress on.
    func testRoundTripPreservesNilMessageIdHeader() throws {
        let data = try loadFixtureData()
        let decoder = makeDecoder()
        let original = try decoder.decode(MailSnapshot.self, from: data)
        let reencoded = try makeEncoder().encode(original)
        let roundTripped = try decoder.decode(MailSnapshot.self, from: reencoded)

        let inbox = try XCTUnwrap(
            roundTripped.accounts.first { $0.id == "3E6777FE-4C2B-4110-B304-25D8571E87EB" }?
                .mailboxes.first { $0.role == "inbox" }
        )
        let githubMessage = try XCTUnwrap(inbox.messages.first { $0.id == "58213" })
        XCTAssertNil(githubMessage.messageIdHeader)
    }
}
