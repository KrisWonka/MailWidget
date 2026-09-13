// SnapshotStoreTests.swift
// DataKitTests — Contract 2: SnapshotStore.save() / .load() round trip.
//
// SnapshotStore.swift has no path-injection point (containerURL / fallbackDirectoryURL are private,
// computed straight from FileManager) — see spec.md's own comment that it falls back to
// ~/Library/Application Support/MailWidget/snapshot.json when the App Group container is
// unavailable. In practice `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
// almost never returns nil for an unsandboxed process (confirmed empirically across several
// arbitrary identifiers, entitled or not) — the "falls back to Application Support" branch is
// nearly dead code outside a real App Sandbox. What DataKitTests' *own* bundle actually has is no
// `com.apple.security.application-groups` entitlement of its own (it's a standalone unit-test
// bundle, not hosted inside MailWidgetApp — see project.yml), so `SharedConstants.appGroupIdentifier`
// resolves to its level-3 fallback (`"com.kris.mailwidget"`, no Team ID prefix). Creating a *brand
// new, never-before-provisioned* directory under `~/Library/Group Containers/` for that identifier
// then hits macOS's containermanagerd gate and fails with EPERM — a real, reproducible failure of
// this specific test process's OS-level permissions, not a defect in SnapshotStore's own
// load/save/decode logic (which is what this file actually means to exercise). Since we cannot
// inject a scratch path, every test below operates on whatever `SnapshotStore.snapshotFileURL`
// really resolves to, backs up + restores that exact file around the test so a real snapshot.json
// belonging to the user/app is never lost, and treats "this process isn't allowed to touch that
// path at all" as a skip rather than a failure — same philosophy as the pre-existing "resolved to
// nil" skip below, just covering the "resolved to something, but unusable here" case too.

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
        let directory = url.deletingLastPathComponent()
        let existedBefore = fileManager.fileExists(atPath: url.path)

        // Probe writability *before* touching anything: on a fresh machine (or this test
        // bundle's own, unentitled process — see the file-header note above) the resolved
        // directory may be a brand-new, never-before-provisioned `~/Library/Group Containers/`
        // path that this process has no OS permission to create. That's an environment
        // limitation of this test process, not a bug in SnapshotStore's load/save/decode logic,
        // so it should skip cleanly instead of failing with a confusing error surfaced from deep
        // inside `SnapshotStore.save()`.
        if !existedBefore {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw XCTSkip(
                    "Cannot create \(directory.path) in this process (\(error.localizedDescription)) — " +
                    "likely an unentitled App Group container path this test process isn't allowed to " +
                    "provision. Cannot exercise save/load here."
                )
            }
        }

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
