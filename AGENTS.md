<claude-mem-context>
# Memory Context

# [mail_widget] recent context, 2026-07-29 1:49pm EDT

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision 🚨security_alert 🔐security_note
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 50 obs (22,598t read) | 931,131t work | 98% savings

### Jul 22, 2026
721 4:10a 🟣 DataKitTests — TestSupport.swift shared helpers written with independent oracle re-implementations
726 4:11a 🟣 DataKitTests — AppleScriptProviderErrorTests.swift: error descriptions and protocol conformance only, no fetchSnapshot calls
727 4:12a 🔴 DataKitTests build blocked — project.yml missing GENERATE_INFOPLIST_FILE: YES for XCTest bundle target
728 " 🔵 Envelope Index real-data audit: iCloud direct + 3 Gmail label-only INBOXes confirmed; ROWID ≠ message_id for all 11,712 messages
729 " 🔴 project.yml — DataKitTests target fixed with GENERATE_INFOPLIST_FILE: YES to unblock xcodebuild test
731 " 🔵 xcodebuild test runner has no TCC/Full Disk Access — cannot read Fixtures/, ~/Library/Mail, or App Group snapshot.json from test process
732 " 🔴 ModelsCodableTests.swift — loadFixtureData() updated with embedded JSON fallback to survive TCC-blocked test runner
733 " 🟣 DataKitTests suite green — 22 tests, 0 failures, 8 skipped; xcodebuild test ** TEST SUCCEEDED **
734 " 🔵 DataKit testability defects confirmed — P1: no DI on EnvelopeIndexProvider/SnapshotStore; P2: AppleScriptProvider parsing helpers all private
740 4:42a ⚖️ User feedback: widget UX insufficient — requires mailbox selection, mailbox name header, and deep-link navigation to Mail.app
745 4:45a ⚖️ User rejects phase-2 widget UX — demands mailbox selector, name header, and Mail.app deep-link navigation
748 " 🔵 P0 bug confirmed: AppleScriptProvider strips @domain from Message-IDs, breaking all deep links
749 " 🟣 Contract 8 added: MailAppOpener API — openMessage and openMailbox, spec.md updated
S618 Duplicate edit: locateEnvelopeIndex(mailDirectory:) parameterization already recorded — no new content (Jul 22 at 4:45 AM)
755 4:49a 🟣 MailDeepLink.swift rewritten: double-slash URL format + new mailbox() helper, @ preserved in encoding
756 " 🟣 ResolvedScope and ScopeResolver upgraded: ScopedMessage struct added, accountID threaded through, per-message account tracking enabled
757 4:50a 🟣 Frontend rework actively writing code: MessageRow, SharedComponents, SmallMailView, MediumMailView all updated for Contract 8
758 4:51a 🟣 LargeMailView and ExtraLargeMailView updated: ScopedMessage cascade complete across all four widget sizes
759 " 🟣 App.swift URL handler overhauled: dispatches on url.host, resolves accountId to account name, calls MailAppOpener.openMailbox
760 " 🔵 AppleScript `message id` property confirmed to strip @domain — P0 fix approach: use `all headers of msg` raw header block + regex extraction
770 4:52a 🟣 AppleScriptProvider P0 fix in progress: `all headers of msg` added to AppleScript output as field[13], parseMessage updated to use extractMessageIdHeader
771 4:53a 🟣 AppleScriptProvider P0 fix complete: extractMessageIdHeader, messageIdFromRawHeaders, regex added; all parsing functions promoted to internal
772 " 🟣 DataKitStub.swift updated: Contract 5 (SharedConstants) and Contract 8 (MailAppOpener) stubs added for frontend typecheck isolation
773 4:54a 🟣 EnvelopeIndexProvider P1 complete: init(rootURL:) path injection added, convenience init() delegates to it
S619 Mail widget full rework: fix broken email deep links, add tappable mailbox headers, implement MailAppOpener — all four user UX requirements (Jul 22 at 4:54 AM)
784 4:56a 🟣 EnvelopeIndexProvider.locateEnvelopeIndex refactored to accept mailDirectory: URL parameter, completing P1 path injection
786 4:58a 🟣 Mail widget UX rework — four concrete user requirements
787 " 🔴 DataKit/MailAppOpener.swift created — Contract 8 real implementation
788 " 🟣 P0 and path-injection self-test harnesses written to scratchpad
792 " ⚖️ Team-lead ruling: message:// double-slash format chosen as project standard
S620 Mail widget full rework — fix broken deep links, tappable mailbox headers, MailAppOpener, account display names (four user UX requirements) (Jul 22 at 5:04 AM)
789 5:08a 🔴 AppleScriptProvider P0 fix confirmed with real evidence — @domain now preserved in Message-IDs
790 " 🟣 EnvelopeIndexProvider recipients heuristic resolves real account emails — confirmed on 4 live accounts
791 " ⚖️ message: URL scheme — single colon vs double slash decision raised to team-lead
793 5:10a 🔴 MailAppOpener.swift: comment updated to double-slash but actual URL string not yet changed
S621 Mail widget full rework — all four UX requirements complete, awaiting user retest confirmation (Jul 22 at 5:10 AM)
S629 Widget Large size: mailbox name missing at top, emails still not tappable — diagnosed as stale cached widget extension binary, not a code bug (Jul 22 at 5:16 AM)
### Jul 23, 2026
801 12:26a 🔵 User retest failed: widget header still missing, email deep links still broken after rework
803 12:34a 🔵 Large widget specifically: header missing and email taps broken after rework
804 " 🔵 Widget regression confirmed persistent after fresh install + chronod restart + widget re-add
805 " 🔵 Root cause confirmed: LargeMailView layout overflow causes header to be center-clipped off the top
806 " 🔴 LargeMailView fixed: ViewThatFits replaces hard-coded 7-row count to prevent header center-clipping
S630 Widget Large: header still missing and emails non-tappable — root cause confirmed as SwiftUI layout overflow/center-clipping, fix dispatched to frontend-dev (Jul 23 at 12:35 AM)
807 12:47a 🔴 MediumMailView fixed: ViewThatFits replaces hard-coded 3-row count that also overflowed 158pt height
S632 Layout overflow P0 fully fixed, verified with 8 PNG renders, new Release build installed — user asked to retest all 3 requirements (Jul 23 at 12:49 AM)
808 12:55a 🔴 ExtraLargeMailView fixed: ViewThatFits with per-column candidate counts replaces hard-coded 12-message two-column layout
810 " ✅ ImageRenderer harness expanded to render all 4 widget sizes as PNG for visual verification
812 " ✅ Render harness expanded with edge-case scenarios: few-message account and all-accounts scope
813 " 🔵 ViewThatFits actual row choices with real data: Large=5, Medium=2 (not 3), XL=5/column
809 12:56a ✅ MessageRow snippet font reduced from .caption to .caption2 to recover vertical headroom
S633 Fix requirements 2 and 3 (tap email → open in Mail; tap mailbox header → open inbox) — two P0 bugs identified and backend fix now delivered (Jul 23 at 12:57 AM)
814 1:00a 🔵 Requirements 2 and 3 still broken after layout fix: tapping emails and mailbox header remain non-functional
815 1:15a 🔵 Two new P0 bugs identified: SwiftUI swallows kAEGetURL and AppleScript uses wrong class name `mail viewer`
S634 Fix requirements 2 and 3 for MailWidget — backend-dev delivered AppleScript fix; waiting on frontend-dev App.swift URL handler fix (Jul 23 at 1:16 AM)
819 1:21a 🔵 User reconfirms requirements 2 and 3 still broken after backend-dev fix delivery
820 " 🔴 App.swift: NSAppleEventManager explicit kAEGetURL handler registered in applicationDidFinishLaunching — fixes mailwidget:// URL delivery
821 1:23a ✅ App.swift: `import CoreServices` added to provide AEEventClass, AEEventID, keyDirectObject symbols
822 1:24a 🔵 kInternetEventClass and kAEGetURL not in Xcode 26.6 macOS SDK — only hit is deprecated InternetConfig.h; must use computed 'GURL' fourCharCode instead
823 " 🔴 frontend-dev DONE: App.swift NSAppleEventManager fix delivered — both P0 fixes now complete, ready for xcodegen+build
S635 Fix requirements 2 and 3 (tap email → open in Mail; tap mailbox header → open inbox) — both P0 fixes delivered, build installed, end-to-end chain verified from terminal, awaiting user widget test (Jul 23 at 1:27 AM)
**Investigated**: - Confirmed message:// deep link works end-to-end: `open "message://%3C...%3E"` opens correct email in Mail.app
    - Confirmed mailwidget:// URLs were silently dropped: `open "mailwidget://..."` produced zero log events — SwiftUI MenuBarExtra intercepts kAEGetURL before application(_:open:) fires
    - osacompile on original openMailbox AppleScript: compile error -2741 at `mail viewer` — class does not exist in Mail.app dictionary
    - Correct AppleScript class verified: `message viewer` / `message viewers`
    - kInternetEventClass and kAEGetURL grepped across entire Xcode 26.6 macOS SDK: NOT declared anywhere in modern headers (only hit: deprecated InternetConfig.h, unrelated)
    - Both the Apple Event class and event ID for URL-scheme handling are four-char code 'GURL' — stable, decades-old OS constant
    - import CoreServices required explicitly; Foundation pulls Apple Events types in internally but does not re-export them to Swift
    - End-to-end link verified from terminal: `open "mailwidget://openMailbox?accountId=..."` → Mail activated and navigated to account inbox

**Learned**: - SwiftUI MenuBarExtra intercepts kAEGetURL Apple Events — application(_:open:) is NEVER called for custom URL schemes in SwiftUI-lifecycle apps
    - Fix: NSAppleEventManager.shared().setEventHandler in applicationDidFinishLaunching overrides SwiftUI's handler (last-registered wins)
    - kInternetEventClass/kAEGetURL are NOT in Xcode 26.6 macOS SDK; must compute 'GURL' via fourCharCode helper: `string.utf8.reduce(0) { ($0 &lt;&lt; 8) | UInt32($1) }`
    - Mail.app AppleScript dictionary class is `message viewer`, NOT `mail viewer` — osacompile error -2741 is the symptom
    - Inbox name case varies by account/server: "INBOX" vs "Inbox" — need inner try/on error fallback
    - import CoreServices needed for AEEventClass, AEEventID, keyDirectObject in Swift files
    - When widget is in dimmed sleep state, first tap only wakes the desktop — second tap is the actual action
    - First openMailbox call triggers macOS "MailWidget wants to control Mail" Automation permission prompt — user must click Allow

**Completed**: DataKit/MailAppOpener.swift (backend-dev fix):
    - `mail viewer windows` → `message viewers`, `mail viewer 1` → `message viewer 1`
    - Inner try/on error: tries mailbox "INBOX" first, falls back to "Inbox"
    - scriptSource visibility: private → internal (for osacompile validation)
    - osacompile: all 3 variants pass (nil, named, double-quote-escaped) — exit 0
    - DataKit typecheck: exit 0

    MailWidgetApp/App.swift (frontend-dev fix):
    - NSAppleEventManager.shared().setEventHandler registered in applicationDidFinishLaunching
    - fourCharCode("GURL") helper replaces missing kInternetEventClass/kAEGetURL constants
    - @objc handleGetURLEvent(_:withReplyEvent:) extracts URL from keyDirectObject parameter
    - import CoreServices added
    - application(_:open:) kept as documented secondary/fallback path
    - NSLog("MailWidget: handling URL \(url.absoluteString)") added to handle(_:) for diagnostics
    - MailWidgetApp + DataKit joint typecheck: EXIT 0, 0 errors, 0 warnings

    Build cycle:
    - xcodegen + xcodebuild Release run
    - New binary installed and restarted
    - End-to-end chain verified from terminal: mailwidget://openMailbox → Mail activated + inbox selected
    - All 3 requirements: req 1 (header visible) fixed in prior session; req 2 (tap email) and req 3 (tap mailbox) fixed in this session

**Next Steps**: Waiting for user to test all three tap behaviors on the actual desktop widget:
    1. Tap mailbox name at top → Mail opens and selects account inbox (first time: Allow the "MailWidget wants to control Mail" permission prompt)
    2. Tap an email row → Mail opens that specific email
    3. Tap card blank area → Mail activates
    If any of these still fail, check Console.app/log show filtered on "MailWidget: handling URL" to see if the URL is being delivered to the handler.


Access 931k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>