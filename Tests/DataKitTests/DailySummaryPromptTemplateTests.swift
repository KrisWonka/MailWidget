import Foundation
import XCTest

/// 模板渲染是四个调度出口共用的地基。渲染漏了占位符，交给 agent 的就是一份带
/// `<DATA_DIR>` 字样的半成品提示词——agent 会照着字面量去写一个不存在的路径，
/// 而且失败得很晚（要等到第二天定时任务跑完才发现日报没来）。
final class DailySummaryPromptTemplateTests: XCTestCase {

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
        for placeholder in DailySummaryPromptTemplate.Placeholder.allCases {
            XCTAssertTrue(
                DailySummaryPromptTemplate.body.contains(placeholder.rawValue),
                "模板正文没有用到 \(placeholder.rawValue)，渲染逻辑与正文脱节了"
            )
        }
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
}
