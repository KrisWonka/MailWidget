// SnapshotStoreTests.swift
// DataKitTests — Contract 2: SnapshotStore.save() / .load() round trip.
//
// SnapshotStore.swift has no path-injection point (containerURL / fallbackDirectoryURL are private,
// computed straight from FileManager) — see spec.md's own comment that it falls back to
// ~/Library/Application Support/MailWidget/snapshot.json when the App Group container is
// unavailable (as it is expected to be for a plain unit-test bundle with no app-group entitlement).
// Since we cannot inject a scratch path, every test below operates on whatever
// `SnapshotStore.snapshotFileURL` really resolves to, and backs up + restores that exact file around
// the test so a real snapshot.json belonging to the user/app is never lost.

import XCTest
import Foundation

final class SnapshotStoreTests: XCTestCase {

    private func sampleSnapshot() -> MailSnapshot {
        MailSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            providerKind: "envelopeIndex",
            accounts: [
                AccountSummary(
                    id: "TEST-ACCOUNT-UUID",
                    name: "Test Account",
                    email: "test@example.com",
                    mailboxes: [
                        MailboxSummary(
                            id: "imap://TEST-ACCOUNT-UUID/INBOX",
                            name: "Inbox",
                            role: "inbox",
                            unreadCount: 2,
                            messages: [
                                MessageSummary(
                                    id: "msg-1@example.com",
                                    messageIdHeader: "msg-1@example.com",
                                    sender: "Alice",
                                    senderEmail: "alice@example.com",
                                    subject: "Hello",
                                    snippet: "Hi there, this is a test snippet.",
                                    date: Date(timeIntervalSince1970: 1_800_000_100),
                                    isRead: false,
                                    isFlagged: true
                                ),
                                MessageSummary(
                                    id: "12345",
                                    messageIdHeader: nil,
                                    sender: "Bob",
                                    senderEmail: "bob@example.com",
                                    subject: "No RFC id",
                                    snippet: "",
                                    date: Date(timeIntervalSince1970: 1_800_000_050),
                                    isRead: true,
                                    isFlagged: false
                                )
                            ]
                        )
                    ]
                )
            ]
        )
    }

    /// Backs up whatever currently lives at `SnapshotStore.snapshotFileURL` (if anything), runs `body`,
    /// then unconditionally restores the original state — deleting the file if none existed before, or
    /// rewriting the exact original bytes if one did. Skips (does not fail) if the store can't resolve
    /// any path at all in this process.
    private func withBackedUpSnapshotFile(_ body: (URL) throws -> Void) throws {
        guard let url = SnapshotStore.snapshotFileURL else {
            throw XCTSkip("SnapshotStore.snapshotFileURL resolved to nil (no App Group container and no Application Support directory available in this test process) — cannot exercise save/load.")
        }
        let fileManager = FileManager.default
        let existedBefore = fileManager.fileExists(atPath: url.path)
        let backupData = existedBefore ? try? Data(contentsOf: url) : nil
        if existedBefore && backupData == nil {
            throw XCTSkip("A snapshot.json exists at \(url.path) but could not be read for backup — refusing to touch it.")
        }

        defer {
            if let backupData {
                try? backupData.write(to: url, options: [.atomic])
            } else {
                try? fileManager.removeItem(at: url)
            }
        }

        try body(url)
    }

    func testSaveThenLoadRoundTrips() throws {
        try withBackedUpSnapshotFile { _ in
            let snapshot = sampleSnapshot()
            try SnapshotStore.save(snapshot)

            let loaded = try XCTUnwrap(SnapshotStore.load(), "load() returned nil right after save()")
            assertSnapshotsEqual(snapshot, loaded)
        }
    }

    func testSaveOverwritesPreviousSnapshot() throws {
        try withBackedUpSnapshotFile { _ in
            try SnapshotStore.save(sampleSnapshot())

            let second = MailSnapshot(generatedAt: Date(timeIntervalSince1970: 1_900_000_000), providerKind: "appleScript", accounts: [])
            try SnapshotStore.save(second)

            let loaded = try XCTUnwrap(SnapshotStore.load())
            assertSnapshotsEqual(second, loaded)
        }
    }

    func testLoadReturnsNilWhenNoFileExists() throws {
        try withBackedUpSnapshotFile { url in
            try? FileManager.default.removeItem(at: url)
            XCTAssertNil(SnapshotStore.load())
        }
    }

    func testLoadReturnsNilForUndecodableData() throws {
        try withBackedUpSnapshotFile { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{ not valid json".utf8).write(to: url, options: [.atomic])
            XCTAssertNil(SnapshotStore.load())
        }
    }
}
