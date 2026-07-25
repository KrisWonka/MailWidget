// TestSupport.swift
// DataKitTests — shared helpers used across multiple test files.
//
// DataKit's model types (Models.swift) are Codable but not Equatable, so we compare them
// field-by-field here instead of adding a retroactive Equatable conformance to production types
// we aren't allowed to touch.

import XCTest
import Foundation

/// Deep, field-by-field comparison of two MailSnapshot values. Reports the first-level
/// XCTAssert failures at the caller's file/line so failures point at the actual test, not here.
func assertSnapshotsEqual(
    _ lhs: MailSnapshot,
    _ rhs: MailSnapshot,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(lhs.providerKind, rhs.providerKind, "providerKind", file: file, line: line)
    XCTAssertEqual(
        lhs.generatedAt.timeIntervalSince1970, rhs.generatedAt.timeIntervalSince1970,
        accuracy: 0.001, "generatedAt", file: file, line: line
    )
    XCTAssertEqual(lhs.accounts.count, rhs.accounts.count, "accounts.count", file: file, line: line)
    for (a, b) in zip(lhs.accounts, rhs.accounts) {
        XCTAssertEqual(a.id, b.id, "account.id", file: file, line: line)
        XCTAssertEqual(a.name, b.name, "account.name", file: file, line: line)
        XCTAssertEqual(a.email, b.email, "account.email", file: file, line: line)
        XCTAssertEqual(a.mailboxes.count, b.mailboxes.count, "account.mailboxes.count", file: file, line: line)
        for (mA, mB) in zip(a.mailboxes, b.mailboxes) {
            XCTAssertEqual(mA.id, mB.id, "mailbox.id", file: file, line: line)
            XCTAssertEqual(mA.name, mB.name, "mailbox.name", file: file, line: line)
            XCTAssertEqual(mA.role, mB.role, "mailbox.role", file: file, line: line)
            XCTAssertEqual(mA.unreadCount, mB.unreadCount, "mailbox.unreadCount", file: file, line: line)
            XCTAssertEqual(mA.messages.count, mB.messages.count, "mailbox.messages.count", file: file, line: line)
            for (msgA, msgB) in zip(mA.messages, mB.messages) {
                XCTAssertEqual(msgA.id, msgB.id, "message.id", file: file, line: line)
                XCTAssertEqual(msgA.messageIdHeader, msgB.messageIdHeader, "message.messageIdHeader", file: file, line: line)
                XCTAssertEqual(msgA.sender, msgB.sender, "message.sender", file: file, line: line)
                XCTAssertEqual(msgA.senderEmail, msgB.senderEmail, "message.senderEmail", file: file, line: line)
                XCTAssertEqual(msgA.subject, msgB.subject, "message.subject", file: file, line: line)
                XCTAssertEqual(msgA.snippet, msgB.snippet, "message.snippet", file: file, line: line)
                XCTAssertEqual(
                    msgA.date.timeIntervalSince1970, msgB.date.timeIntervalSince1970,
                    accuracy: 0.001, "message.date", file: file, line: line
                )
                XCTAssertEqual(msgA.isRead, msgB.isRead, "message.isRead", file: file, line: line)
                XCTAssertEqual(msgA.isFlagged, msgB.isFlagged, "message.isFlagged", file: file, line: line)
            }
        }
    }
}

/// Mirrors EnvelopeIndexProvider's private `stripAngleBrackets` for use as an independent oracle
/// in tests. Deliberately re-implemented here (not `@testable`-reached) since it's `private` in
/// DataKit and we are not allowed to modify DataKit's access levels.
func stripAngleBracketsForTest(_ value: String?) -> String? {
    guard var result = value, !result.isEmpty else { return nil }
    if result.hasPrefix("<") { result.removeFirst() }
    if result.hasSuffix(">") { result.removeLast() }
    return result.isEmpty ? nil : result
}

/// Mirrors EnvelopeIndexProvider's private `makeSnippet` for use as an independent oracle in tests.
func makeSnippetForTest(_ raw: String?) -> String {
    guard let raw else { return "" }
    let collapsed = raw
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard collapsed.count > 120 else { return collapsed }
    let cutoff = collapsed.index(collapsed.startIndex, offsetBy: 117)
    return String(collapsed[..<cutoff]) + "…"
}
