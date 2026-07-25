// ProviderProbeAndFactoryTests.swift
// DataKitTests — Contract 7 (ProviderProbe.run()) and the MailDataProviderFactory selector.
//
// Both of these are safe to call for real: ProviderProbe.run() and EnvelopeIndexProvider() only ever
// open the Envelope Index read-only and validate its schema — they never touch AppleScript/Mail.app.
// We deliberately never call `.fetchSnapshot()` on whatever MailDataProviderFactory.makeActiveProvider()
// returns in this file: if it ever resolved to AppleScriptProvider, fetchSnapshot() would actually
// drive Mail.app / pop an Automation permission prompt, which spec.md's test brief explicitly forbids.

import XCTest
import Foundation

final class ProviderProbeAndFactoryTests: XCTestCase {

    func testProbeReportFieldsAreInternallyConsistent() {
        let report = ProviderProbe.run()

        XCTAssertTrue(
            ["envelopeIndex", "appleScript"].contains(report.activeProvider),
            "activeProvider was \"\(report.activeProvider)\", expected one of envelopeIndex/appleScript"
        )
        XCTAssertFalse(report.envelopeIndexDetail.isEmpty, "envelopeIndexDetail should always carry a human-readable explanation")

        // The two fields must agree with each other: envelopeIndexAvailable == true iff the active
        // provider actually is the envelope-index one.
        XCTAssertEqual(report.envelopeIndexAvailable, report.activeProvider == "envelopeIndex")
    }

    func testProbeReportMatchesDirectEnvelopeIndexProviderInitOutcome() {
        let report = ProviderProbe.run()
        let initSucceeds: Bool
        do {
            _ = try EnvelopeIndexProvider()
            initSucceeds = true
        } catch {
            initSucceeds = false
        }
        XCTAssertEqual(
            report.envelopeIndexAvailable, initSucceeds,
            "ProviderProbe.run()'s envelopeIndexAvailable must track whether EnvelopeIndexProvider() actually throws"
        )
    }

    func testFactoryReturnsEnvelopeIndexProviderWheneverProbeSaysAvailable() {
        let report = ProviderProbe.run()
        let provider = MailDataProviderFactory.makeActiveProvider()

        if report.envelopeIndexAvailable {
            XCTAssertTrue(provider is EnvelopeIndexProvider, "Probe reported envelope index available, but factory did not return an EnvelopeIndexProvider")
        } else {
            XCTAssertTrue(provider is AppleScriptProvider, "Probe reported envelope index unavailable, but factory did not fall back to AppleScriptProvider")
        }
        // Deliberately not calling provider.fetchSnapshot() here — see file header.
    }
}
