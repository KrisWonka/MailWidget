import Foundation
import XCTest

/// 2026-09-14 实录：09:29 发布了一份带 `immediate` 的日报（回复口语诊所改约），用户
/// 3 分钟后点了「立即刷新」，增量查询自然零封新邮件，agent 按规则发 `items: []`，
/// 把那条还没办的事整个抹掉——用户看到的是"widget 什么都不显示了"。
final class EmptyPayloadGuardTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func decide(incoming: Int, existing: Int, existingAt: Date?, now: Date) -> EmptyPayloadDecision {
        DailySummaryPublisher.emptyPayloadDecision(
            incomingItemCount: incoming,
            existingItemCount: existing,
            existingGeneratedAt: existingAt,
            now: now,
            calendar: calendar
        )
    }

    /// 本次事故的精确复现：09:29 的 6 条，09:33 来一份 0 条 —— 必须保留。
    func testEmptyPayloadDoesNotEraseABriefPublishedMinutesAgo() {
        let decision = decide(
            incoming: 0, existing: 6,
            existingAt: at(2026, 9, 14, 9, 29),
            now: at(2026, 9, 14, 9, 33)
        )
        XCTAssertEqual(decision, .keepExisting(existingItemCount: 6))
    }

    /// 有内容的载荷永远放行——守门只管"空盖非空"，不能挡住正常更新。
    func testNonEmptyPayloadAlwaysPublishes() {
        XCTAssertEqual(
            decide(incoming: 3, existing: 6, existingAt: at(2026, 9, 14, 9, 29), now: at(2026, 9, 14, 9, 33)),
            .publish
        )
    }

    /// 已有的本来就是空的：空盖空，无所谓，放行（否则 generatedAt 永远停在旧值）。
    func testEmptyOverEmptyPublishes() {
        XCTAssertEqual(
            decide(incoming: 0, existing: 0, existingAt: at(2026, 9, 14, 9, 29), now: at(2026, 9, 14, 9, 33)),
            .publish
        )
    }

    /// 新的一天该重新开始：昨天的日报不该把今早定时任务发的空日报挡掉。
    func testEmptyPayloadReplacesYesterdaysBrief() {
        XCTAssertEqual(
            decide(incoming: 0, existing: 6, existingAt: at(2026, 9, 13, 21, 0), now: at(2026, 9, 14, 9, 7)),
            .publish
        )
    }

    /// 跨日边界：昨天 23:59 的日报，今天 00:01 的空载荷放行（不同自然日）。
    func testBoundaryJustAfterMidnight() {
        XCTAssertEqual(
            decide(incoming: 0, existing: 6, existingAt: at(2026, 9, 13, 23, 59), now: at(2026, 9, 14, 0, 1)),
            .publish
        )
    }

    /// 同一天的另一头：00:01 发的日报，23:59 来一份空的，仍然要保留。
    func testSameDayFarApartStillKeeps() {
        XCTAssertEqual(
            decide(incoming: 0, existing: 6, existingAt: at(2026, 9, 14, 0, 1), now: at(2026, 9, 14, 23, 59)),
            .keepExisting(existingItemCount: 6)
        )
    }

    /// 没有已有日报（首次使用）——放行，否则 widget 永远出不来第一份。
    func testNoExistingBriefPublishes() {
        XCTAssertEqual(decide(incoming: 0, existing: 0, existingAt: nil, now: at(2026, 9, 14, 9, 33)), .publish)
    }
}
