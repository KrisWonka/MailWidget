import Foundation
import XCTest

/// 2026-09-15 第二台机器实录：codex 的游标一直写不进去，agent 每轮都报
/// 「`.codex` 目录受环境只读限制，游标未能写入；下次运行可能重复检索最近 24 小时邮件」。
/// 根因是游标路径被指到了 `~/.codex/`——**codex 自己的沙箱把那个目录设为只读**。
/// 后果是每次都重扫最近 24 小时、每次产出几乎同一份简报，用户体感是"刷新了但没变化"。
final class CursorPathTests: XCTestCase {

    /// 游标必须落在本 app 的数据目录里，那里在 codex 沙箱的可写范围内。
    func testCodexCursorLivesInAppDataDirectory() {
        let path = DailySummaryPromptTemplate.cursorPath(for: DailySource.codex)
        XCTAssertTrue(
            path.hasPrefix(DailySummaryConstants.dataDirectoryURL.path),
            "codex 游标不在数据目录里：\(path)"
        )
    }

    /// 明确钉死：绝不能再指回 `~/.codex`——那是 codex 自己的配置目录，它只读。
    func testCodexCursorIsNotInsideCodexConfigDirectory() {
        let path = DailySummaryPromptTemplate.cursorPath(for: DailySource.codex)
        XCTAssertFalse(path.contains("/.codex/"), "游标又被指回 codex 的只读配置目录：\(path)")
    }

    /// 每个来源各自一份游标，不能互相覆盖。
    func testEachSourceHasItsOwnCursor() {
        let codex = DailySummaryPromptTemplate.cursorPath(for: DailySource.codex)
        let claude = DailySummaryPromptTemplate.cursorPath(for: DailySource.claude)
        XCTAssertNotEqual(codex, claude)
    }

    /// 渲染出来的提示词里，游标路径必须已经被替换掉，不能留占位符。
    func testRenderedPromptCarriesTheCursorPath() {
        let rendered = DailySummaryPromptTemplate.render(for: DailySource.codex)
        XCTAssertFalse(rendered.contains("<CURSOR_FILE>"))
        XCTAssertTrue(rendered.contains(DailySummaryPromptTemplate.cursorPath(for: DailySource.codex)))
    }

    /// 迁移只在新位置为空时发生，绝不覆盖已有游标——覆盖会把增量位置倒退回旧值。
    func testMigrationNeverOverwritesAnExistingCursor() throws {
        let destination = DailySource.cursorFileURL(for: DailySource.codex)
        let manager = FileManager.default
        let hadOriginal = manager.fileExists(atPath: destination.path)
        let original = hadOriginal ? try Data(contentsOf: destination) : nil
        defer {
            if let original { try? original.write(to: destination) }
            else if !hadOriginal { try? manager.removeItem(at: destination) }
        }

        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sentinel = Data("cursor: 999999999\n".utf8)
        try sentinel.write(to: destination)

        DailySummaryPromptTemplate.migrateLegacyCodexCursorIfNeeded(for: DailySource.codex)

        XCTAssertEqual(try Data(contentsOf: destination), sentinel, "已有游标被迁移覆盖了")
    }

    /// 非 codex 来源不触发迁移——别把 codex 的游标搬到 claude 头上。
    func testMigrationIgnoresOtherSources() {
        let destination = DailySource.cursorFileURL(for: DailySource.claude)
        let existedBefore = FileManager.default.fileExists(atPath: destination.path)
        DailySummaryPromptTemplate.migrateLegacyCodexCursorIfNeeded(for: DailySource.claude)
        XCTAssertEqual(FileManager.default.fileExists(atPath: destination.path), existedBefore)
    }
}
