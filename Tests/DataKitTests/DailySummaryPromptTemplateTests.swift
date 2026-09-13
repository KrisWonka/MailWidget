import Foundation
import XCTest

/// 模板渲染是四个调度出口共用的地基。渲染漏了占位符，交给 agent 的就是一份带
/// `<DATA_DIR>` 字样的半成品提示词——agent 会照着字面量去写一个不存在的路径，
/// 而且失败得很晚（要等到第二天定时任务跑完才发现日报没来）。
final class DailySummaryPromptTemplateTests: XCTestCase {
    private var previousConfiguredMailbox: String?

    /// `<<MAILBOX_NOT_CONFIGURED>>` 哨兵只在邮箱未配置时才会出现在正文里；这里的
    /// "渲染后不应残留占位符"用例本意是测"三个真占位符都替换干净了"，所以显式配上
    /// 一个邮箱，把哨兵变量控制住，不让它跟别的占位符混在一起断言。哨兵本身的行为
    /// 由 `testRendersMailboxSentinelWhenUnconfigured` 单独覆盖。
    override func setUpWithError() throws {
        previousConfiguredMailbox = DailySummaryConstants.configuredMailbox
        DailySummaryConstants.configuredMailbox = "friend@example.com"
    }

    override func tearDownWithError() throws {
        DailySummaryConstants.configuredMailbox = previousConfiguredMailbox
    }

    func testRenderLeavesNoPlaceholders() {
        for source in DailySource.builtIn + ["gemini", "some-agent-7"] {
            let rendered = DailySummaryPromptTemplate.render(for: source)
            XCTAssertEqual(
                DailySummaryPromptTemplate.unresolvedPlaceholders(in: rendered), [],
                "来源 \(source) 渲染后仍有占位符"
            )
        }
    }

    func testEveryPlaceholderAppearsInTemplateBody() {
        for placeholder in DailySummaryPromptTemplate.Placeholder.allCases
        where placeholder != .mailboxNotConfigured {
            XCTAssertTrue(
                DailySummaryPromptTemplate.body.contains(placeholder.rawValue),
                "模板正文没有用到 \(placeholder.rawValue)，渲染逻辑与正文脱节了"
            )
        }
    }

    /// 邮箱未配置时，正文里原本要插入邮箱地址的地方必须换成明确的哨兵，而不是悄悄
    /// 渲染出一段"for ，publish it to..."这种带空洞的句子——那样 agent 会照着
    /// 一份看起来完整、实则邮箱缺失的提示词去跑，错得很隐蔽。
    func testRendersMailboxSentinelWhenUnconfigured() {
        DailySummaryConstants.configuredMailbox = nil

        let rendered = DailySummaryPromptTemplate.render(for: DailySource.claude)

        XCTAssertTrue(
            DailySummaryPromptTemplate.unresolvedPlaceholders(in: rendered)
                .contains(.mailboxNotConfigured),
            "未配置邮箱时必须能被 unresolvedPlaceholders 检出，调用方才能据此拒绝半成品提示词"
        )
        XCTAssertFalse(rendered.contains("for  and"), "不能悄悄渲染出空邮箱")
    }

    func testIngestCommandCarriesSourceAndQuotesPaths() {
        let command = DailySummaryPromptTemplate.ingestCommand(for: "gemini")
        XCTAssertTrue(command.hasSuffix("--source gemini"))
        XCTAssertTrue(command.contains("--ingest"))
        XCTAssertTrue(command.contains("\"\(DailySummaryConstants.dataDirectoryURL.path)/\(DailySummaryConstants.summaryFilename)\""),
                      "载荷路径必须加引号——它含空格（Application Support）")
    }

    /// Codex 必须继续用它自己的 memory.md：那个文件存着历史增量游标，换成
    /// cursor-codex.md 会从零开始，导致邮件重复或漏报。
    func testCodexKeepsItsOwnCursorFile() {
        let codexCursor = DailySummaryPromptTemplate.cursorPath(for: DailySource.codex)
        XCTAssertTrue(codexCursor.hasSuffix(".codex/automations/daily-gmail-summary/memory.md"))

        let otherCursor = DailySummaryPromptTemplate.cursorPath(for: DailySource.claude)
        XCTAssertTrue(otherCursor.hasSuffix("cursor-claude.md"))
        XCTAssertNotEqual(codexCursor, otherCursor)
    }

    func testRenderedPromptStatesTheThreeContractSteps() {
        let rendered = DailySummaryPromptTemplate.render(for: DailySource.claude)
        XCTAssertTrue(rendered.contains(DailySummaryConstants.summaryFilename))
        XCTAssertTrue(rendered.contains("--source claude"))
        XCTAssertTrue(rendered.contains("cursor-claude.md"))
        XCTAssertTrue(rendered.contains("messageIdHeader"), "模板必须要求产出 Message-ID，否则点日报进不了 Mail")
        XCTAssertTrue(rendered.contains("Exit code 3"), "模板必须解释退出码 3 不是错误")
    }

    func testSourceIDValidation() {
        for good in ["codex", "claude", "gemini", "a", "a-b-9", String(repeating: "a", count: 32)] {
            XCTAssertTrue(DailySource.isValidID(good), "\(good) 应该合法")
        }
        for bad in ["", "-lead", "UPPER", "has space", "has_underscore", "a.b",
                    String(repeating: "a", count: 33)] {
            XCTAssertFalse(DailySource.isValidID(bad), "\(bad) 应该非法")
        }
    }

    // MARK: - 时区跟随本机

    /// 2026-09-13 第二台机器实录：提示词把时区写死成 `America/New_York`，而那台机器在
    /// `America/Los_Angeles`，日报一直按早 3 小时的时间判断「今日必办」。
    func testPromptUsesLocalTimeZoneNotHardcodedEastern() {
        let rendered = DailySummaryPromptTemplate.body
        let local = TimeZone.current.identifier
        XCTAssertTrue(rendered.contains(local), "提示词里没有本机时区 \(local)")
        if local != "America/New_York" {
            XCTAssertFalse(
                rendered.contains("America/New_York"),
                "提示词仍然写死了原作者的时区"
            )
        }
    }

    /// `body` 是 `static var` 而不是 `static let`（`static let` 会把插值冻结在首次访问），
    /// 时区同理必须每次读取时重新求值。
    func testTimeZoneIdentifierMatchesCurrent() {
        XCTAssertEqual(DailySummaryPromptTemplate.localTimeZoneIdentifier, TimeZone.current.identifier)
    }
}
