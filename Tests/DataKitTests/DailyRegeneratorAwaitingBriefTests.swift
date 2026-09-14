import Foundation
import XCTest

/// 2026-09-14：「widget 该不该显示生成中」与「还有没有 agent 进程在跑」被刻意拆成两个
/// 判据。这组测试钉住"为什么不能合并"——合并会在两个方向上各坏一次。
final class DailyRegeneratorAwaitingBriefTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_000_000)

    private func awaiting(publishedAt: Date?, afterSeconds: TimeInterval) -> Date? {
        DailyRegenerator.awaitingBriefSince(
            startedAt: started,
            lastPublishedAt: publishedAt,
            now: started.addingTimeInterval(afterSeconds)
        )
    }

    func testNotAwaitingWhenNothingStarted() {
        XCTAssertNil(DailyRegenerator.awaitingBriefSince(startedAt: nil, lastPublishedAt: nil, now: started))
    }

    /// 刚点下去，还没有任何日报落地 —— 显示生成中，并且要能拿到起始时刻（计时器要用）。
    func testAwaitingRightAfterStart() {
        XCTAssertEqual(awaiting(publishedAt: nil, afterSeconds: 5), started)
    }

    /// 上一份日报是本次运行**之前**发布的，不算数——否则每次点刷新都会立刻"完成"。
    func testStalePublicationDoesNotEndTheWait() {
        let old = started.addingTimeInterval(-3600)
        XCTAssertEqual(awaiting(publishedAt: old, afterSeconds: 60), started)
    }

    /// 核心场景：日报落地了，但 agent 进程还在写游标、打总结。实测这段有 28 秒。
    /// 等待必须在**落地那一刻**结束，不是进程退出那一刻。
    func testPublicationEndsTheWaitEvenWhileAgentStillRunning() {
        let published = started.addingTimeInterval(258)   // 00:50:04
        XCTAssertNil(awaiting(publishedAt: published, afterSeconds: 286))  // 00:50:32 进程才退出
    }

    /// 同一秒内发布也算送达——发布是另一个进程写的时间戳，精度有限，用 `>=` 不是 `>`。
    func testPublicationInTheSameSecondCounts() {
        XCTAssertNil(awaiting(publishedAt: started, afterSeconds: 1))
    }

    /// 超过 staleAfter 一律不再显示生成中，哪怕一直没发布——这是进程被杀死/系统睡眠
    /// 打断 terminationHandler 时的兜底，不能让 widget 永久挂着。
    func testGoesQuietAfterStaleWindow() {
        XCTAssertNil(awaiting(publishedAt: nil, afterSeconds: DailyRegenerator.staleAfter + 1))
        XCTAssertEqual(awaiting(publishedAt: nil, afterSeconds: DailyRegenerator.staleAfter - 1), started)
    }

    /// 反方向的约束：`awaitingBriefSince` 提前结束**不得**让防重入判据跟着放行。
    /// 看门狗必须严格早于 staleAfter，这样"能再点一次"时上一个进程一定已经被杀掉。
    /// 若哪天有人把两个判据合并，这条会挂。
    func testReentrancyGuardOutlivesTheVisualWait() {
        XCTAssertLessThan(DailyRegenerator.watchdogTimeout, DailyRegenerator.staleAfter)
    }
}
