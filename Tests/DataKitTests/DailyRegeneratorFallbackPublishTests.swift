// DailyRegeneratorFallbackPublishTests.swift
// DataKitTests — 真机部署实录：codex 把 latest.json 写到了交接目录，却从没执行
// --ingest，App Group 里没有日报、widget 一直是空的，agent 却报告成功。
// `DailyRegenerator.fallbackPublishDecision` 是"该不该由宿主自己兜底发布"的纯判定，
// 只测这一个函数——用伪造的时间戳，不碰真实文件系统/App Group（那部分是薄 IO 层
// `performFallbackPublishIfNeeded`，private，且需要真实 App Group 容器，交给
// scratchpad harness 或真机验证）。

import XCTest
import Foundation

final class DailyRegeneratorFallbackPublishTests: XCTestCase {

    private let runStartedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testSkipsWhenNoStagingFileExists() {
        let decision = DailyRegenerator.fallbackPublishDecision(
            stagingModifiedAt: nil,
            runStartedAt: runStartedAt,
            stagingGeneratedAt: nil,
            publishedGeneratedAt: nil
        )
        guard case .skip = decision else {
            return XCTFail("latest.json 不存在时必须 skip，实际是 \(decision)")
        }
    }

    func testSkipsWhenStagingFileIsOlderThanThisRun() {
        // 载荷是上一次运行（或压根没运行完）留下的旧文件——不是这次 agent 写的，
        // 不该被当成"这次生成"发布出去。
        let decision = DailyRegenerator.fallbackPublishDecision(
            stagingModifiedAt: runStartedAt.addingTimeInterval(-60),
            runStartedAt: runStartedAt,
            stagingGeneratedAt: runStartedAt.addingTimeInterval(-60),
            publishedGeneratedAt: nil
        )
        guard case .skip = decision else {
            return XCTFail("旧载荷必须 skip，实际是 \(decision)")
        }
    }

    func testPublishesFreshStagingFileWhenAppGroupHasNoSummaryYet() {
        // 这正是真机实录的场景：agent 这次确实写了新的 latest.json，但 App Group
        // 里还没有任何日报（--ingest 从没成功执行过）。
        let decision = DailyRegenerator.fallbackPublishDecision(
            stagingModifiedAt: runStartedAt.addingTimeInterval(30),
            runStartedAt: runStartedAt,
            stagingGeneratedAt: runStartedAt.addingTimeInterval(30),
            publishedGeneratedAt: nil
        )
        XCTAssertEqual(decision, .publish)
    }

    func testPublishesWhenStagingIsNewerThanWhatsAlreadyPublished() {
        let decision = DailyRegenerator.fallbackPublishDecision(
            stagingModifiedAt: runStartedAt.addingTimeInterval(30),
            runStartedAt: runStartedAt,
            stagingGeneratedAt: runStartedAt.addingTimeInterval(30),
            publishedGeneratedAt: runStartedAt.addingTimeInterval(-3600)
        )
        XCTAssertEqual(decision, .publish)
    }

    func testSkipsWhenAppGroupAlreadyHasAnEquallyOrMoreRecentSummary() {
        // agent 自己已经成功 --ingest 过了（或者另一条路径已经发布过）——不该重复发布，
        // 这也是防止兜底和 agent 自身的 --ingest 竞态时把同一份日报再写一遍。
        let decision = DailyRegenerator.fallbackPublishDecision(
            stagingModifiedAt: runStartedAt.addingTimeInterval(30),
            runStartedAt: runStartedAt,
            stagingGeneratedAt: runStartedAt.addingTimeInterval(30),
            publishedGeneratedAt: runStartedAt.addingTimeInterval(30)
        )
        guard case .skip = decision else {
            return XCTFail("App Group 已经是同样新（或更新）的日报时必须 skip，实际是 \(decision)")
        }
    }

    func testPublishesWhenStagingGeneratedAtFailsToParseButFileIsFresh() {
        // generatedAt 解析不出来不该挡住兜底发布——真正的格式校验交给
        // DailySummaryPublisher.publish 内部的 DailySummaryCodec.decode。
        let decision = DailyRegenerator.fallbackPublishDecision(
            stagingModifiedAt: runStartedAt.addingTimeInterval(30),
            runStartedAt: runStartedAt,
            stagingGeneratedAt: nil,
            publishedGeneratedAt: runStartedAt.addingTimeInterval(-3600)
        )
        XCTAssertEqual(decision, .publish)
    }

    func testBoundaryStagingModifiedExactlyAtRunStartCountsAsThisRun() {
        // >= 而不是 >：runStartedAt 和文件 mtime 都来自 Date()，同一秒截断后可能相等，
        // 不该被当成"更早的旧文件"而误判成陈旧载荷。
        let decision = DailyRegenerator.fallbackPublishDecision(
            stagingModifiedAt: runStartedAt,
            runStartedAt: runStartedAt,
            stagingGeneratedAt: runStartedAt,
            publishedGeneratedAt: nil
        )
        XCTAssertEqual(decision, .publish)
    }
}

/// `TruncatingLogBuffer`（问题 4：日志被 agent 的无关输出淹没）——不是团队交付要求里
/// 明确点名要测的三个问题之一，但它是这次改动里逻辑最容易出 off-by-one 的一块
/// （head/tail 窗口在中间量级会重叠），顺手补一份回归覆盖。
final class TruncatingLogBufferTests: XCTestCase {

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    func testSmallOutputIsReproducedExactly() {
        let buffer = TruncatingLogBuffer(headCapacity: 16, tailCapacity: 16)
        buffer.append(data("hello world"))
        XCTAssertEqual(buffer.render(), data("hello world"))
    }

    func testOutputBetweenHeadAndHeadPlusTailIsReproducedExactlyWithoutDuplication() {
        // headCapacity=4, tailCapacity=4 → 总容量 8；喂 6 字节（"abcdef"），落在
        // (head, head+tail] 之间：曾经的实现在这里会把重叠区间打印两遍。
        let buffer = TruncatingLogBuffer(headCapacity: 4, tailCapacity: 4)
        buffer.append(data("abcdef"))
        XCTAssertEqual(buffer.render(), data("abcdef"), "落在重叠区间时必须精确复原，不能重复/丢字节")
    }

    func testOutputBeyondCapacityIsTruncatedWithMarker() {
        let buffer = TruncatingLogBuffer(headCapacity: 4, tailCapacity: 4)
        buffer.append(data("0123456789")) // 10 字节，超过 4+4=8
        let rendered = String(decoding: buffer.render(), as: UTF8.self)
        XCTAssertTrue(rendered.hasPrefix("0123"), "必须保留前 4 字节：\(rendered)")
        XCTAssertTrue(rendered.hasSuffix("6789"), "必须保留后 4 字节：\(rendered)")
        XCTAssertTrue(rendered.contains("省略 2 字节"), "中间必须标注省略了多少字节：\(rendered)")
    }

    func testMultipleSmallAppendsAccumulateAcrossCalls() {
        // 模拟 readabilityHandler 分多次 chunk 到达的真实场景。
        let buffer = TruncatingLogBuffer(headCapacity: 4, tailCapacity: 4)
        for chunk in ["01", "23", "45", "67", "89"] {
            buffer.append(data(chunk))
        }
        let rendered = String(decoding: buffer.render(), as: UTF8.self)
        XCTAssertTrue(rendered.hasPrefix("0123"))
        XCTAssertTrue(rendered.hasSuffix("6789"))
    }

    func testEmptyBufferRendersEmptyData() {
        let buffer = TruncatingLogBuffer(headCapacity: 4096, tailCapacity: 4096)
        XCTAssertEqual(buffer.render(), Data())
    }
}
