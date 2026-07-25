// AppleScriptProviderErrorTests.swift
// DataKitTests — AppleScriptProvider, WITHOUT ever actually executing it.
//
// spec.md's test brief explicitly says: do not really run AppleScriptProvider (it pops an Automation
// permission dialog and launches Mail.app). AppleScriptProvider's extension-detection gate
// (`isRunningInAppExtension`, checking Bundle.main.infoDictionary["NSExtension"]) is `private`, and so
// are all of its parsing helpers (parseAccounts/parseMessage/splitSender/slugify/...) — see the P2
// testability finding in the delivery report. That leaves exactly one thing in this file that is both
// reachable from outside the file and safe to exercise without running AppleScript: the nested
// `ProviderError` type's `description` strings, which is what this file tests.
//
// We do NOT call AppleScriptProvider().fetchSnapshot() anywhere in this test target: this test
// process is a plain XCTest bundle (no NSExtension key in its Info.plist), so
// `isRunningInAppExtension` would evaluate false and the call would fall through to actually invoking
// `NSAppleScript` against Mail.app — exactly the side effect we've been told to avoid.

import XCTest
import Foundation

final class AppleScriptProviderErrorTests: XCTestCase {

    func testUnavailableInExtensionDescription() {
        let error = AppleScriptProvider.ProviderError.unavailableInExtension
        XCTAssertEqual(error.description, "AppleScriptProvider is host-app only; widget extension cannot drive Mail.app")
    }

    func testAppleScriptUnsupportedDescription() {
        let error = AppleScriptProvider.ProviderError.appleScriptUnsupported
        XCTAssertEqual(error.description, "NSAppleScript is unavailable in this process")
    }

    func testScriptErrorDescriptionIncludesUnderlyingMessage() {
        let error = AppleScriptProvider.ProviderError.scriptError("Not authorized to send Apple events to Mail")
        XCTAssertEqual(error.description, "AppleScript error: Not authorized to send Apple events to Mail")
    }

    func testAppleScriptProviderConformsToMailDataProvider() {
        // Purely a compile-time/type check — does not call fetchSnapshot().
        let provider: MailDataProvider = AppleScriptProvider()
        XCTAssertTrue(provider is AppleScriptProvider)
    }
}
