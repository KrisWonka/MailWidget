import Foundation
import XCTest

/// 2026-09-19：用户报「mailwidget 又不更新了」。查下来不是坏了，是结构问题——日报按游标
/// **增量**检索，每次运行又用结果**整份替换**旧日报。于是：
///   - 刷新一次，还没到期的事项（9/23 口语诊所、9/30 牙科保险截止）会被新邮件整个挤掉；
///   - 一天多跑几次只会更糟，每次都清成"上次之后到的那几封"。
/// 修法是让每一轮都读当前 widget 上那份，结转仍然有效的事项再合并新邮件。
final class CarryForwardTests: XCTestCase {

    /// 镜像必须落在数据目录——claude 和 codex 都读得到的地方。App Group 容器 codex 的
    /// 沙箱进不去（第二台机器实录）。
    func testMirrorLivesInAgentReadableDataDirectory() {
        let path = DailySummaryPublisher.publishedMirrorURL.path
        XCTAssertTrue(path.hasPrefix(DailySummaryConstants.dataDirectoryURL.path), path)
        XCTAssertFalse(path.contains("Group Containers"), "镜像放进了 agent 读不到的 App Group 容器")
    }

    /// 镜像不能和交接目录里 agent 自己写的 latest.json 是同一个文件——发布层拒收时
    /// （比如零条目守门）两者内容不同，读错了就会结转一份从没上过 widget 的东西。
    func testMirrorIsNotTheAgentStagingFile() {
        XCTAssertNotEqual(
            DailySummaryPublisher.publishedMirrorURL.lastPathComponent,
            DailySummaryConstants.summaryFilename
        )
    }

    /// 两个来源渲染出的提示词都必须把镜像路径替换进去，不能留占位符。
    func testRenderedPromptPointsAtTheMirror() {
        for source in [DailySource.claude, DailySource.codex] {
            let rendered = DailySummaryPromptTemplate.render(for: source)
            XCTAssertFalse(rendered.contains("<PUBLISHED_FILE>"), "来源 \(source) 留着占位符")
            XCTAssertTrue(
                rendered.contains(DailySummaryPublisher.publishedMirrorURL.path),
                "来源 \(source) 的提示词里没有镜像路径"
            )
        }
    }

    /// 零邮件的那一轮必须照样发结转项，而不是发空——否则"没有新邮件"会等于"清空待办"。
    func testZeroMessageRunCarriesItemsInsteadOfPublishingEmpty() {
        let rendered = DailySummaryPromptTemplate.render(for: DailySource.claude)
        XCTAssertTrue(rendered.contains("still publish the carried items"), "零邮件规则没有改成发结转项")
        XCTAssertTrue(rendered.contains("nothing carries over either"), "空载荷的适用条件没收紧")
    }

    /// 结转项要保留原来的定位字段，否则点 widget 上那一条就打不开原邮件。
    func testCarriedItemsKeepTheirLocators() {
        let rendered = DailySummaryPromptTemplate.render(for: DailySource.claude)
        XCTAssertTrue(rendered.contains("keeps its original `id`, `gmailURL` and `messageIdHeader`"))
    }

    /// 镜像写入是往返无损的：写进去什么，读出来就是什么。
    func testMirrorRoundTrips() throws {
        // 校验要求 gmailURL 精确指向当前邮箱里同 ID 的那封信（authuser 必须等于配置的邮箱）。
        // 测试进程拿不到 App Group 时邮箱是 nil，校验无从谈起，跳过而不是假装通过。
        guard let mailbox = DailySummaryConstants.configuredMailbox else {
            throw XCTSkip("测试环境没有配置日报邮箱，无法构造能通过校验的载荷")
        }
        let encoded = mailbox.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? mailbox
        let summary = try DailySummaryCodec.decode(Data("""
        {"schemaVersion":1,"mailbox":"\(mailbox)",
         "generatedAt":"2026-09-19T00:00:00-04:00","headline":"测试",
         "items":[{"id":"t1","level":"week","title":"9/23 口语诊所","detail":"d",
                   "gmailURL":"https://mail.google.com/mail/u/0/?authuser=\(encoded)#all/t1"}]}
        """.utf8))
        let url = DailySummaryPublisher.publishedMirrorURL
        let backup = try? Data(contentsOf: url)
        defer {
            if let backup { try? backup.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        }

        DailySummaryPublisher.mirrorPublished(summary)
        let read = try DailySummaryCodec.decode(Data(contentsOf: url))
        XCTAssertEqual(read.items.map(\.title), ["9/23 口语诊所"])
    }
}

/// 时间表与排序规则。
final class DailyBriefScheduleTests: XCTestCase {
    /// 一天至少覆盖早、午、晚——只有早上一次时，白天到的邮件要到第二天才会被看到
    /// （2026-09-19 实录：14 个新线程在 widget 外面等了一整天）。
    func testBriefRunsSeveralTimesADay() {
        for source in [DailySource.claude, DailySource.codex] {
            let hours = AgentRunPolicy.dailyBriefTimes(for: source).map(\.hour)
            XCTAssertGreaterThanOrEqual(hours.count, 3, "来源 \(source) 一天只跑 \(hours.count) 次")
            XCTAssertTrue(hours.contains { $0 < 12 }, "来源 \(source) 没有上午那一轮")
            XCTAssertTrue(hours.contains { $0 >= 17 }, "来源 \(source) 没有傍晚那一轮")
        }
    }

    /// 两个来源错开，免得同时抢 launchd；都避开 8:50 的邮件总结。
    func testSourcesDoNotCollide() {
        let claude = AgentRunPolicy.dailyBriefTimes(for: DailySource.claude).map { $0.hour * 60 + $0.minute }
        let codex = AgentRunPolicy.dailyBriefTimes(for: DailySource.codex).map { $0.hour * 60 + $0.minute }
        XCTAssertTrue(Set(claude).isDisjoint(with: codex))
        XCTAssertFalse((claude + codex).contains(8 * 60 + 50), "撞上了 8:50 的邮件总结")
    }

    /// `week` 必须收紧到 7 天内：原先的定义只有 "a later follow-up"，结果一条七个月后
    /// 截止的培训被判成 week，把 9/30 截止的牙科保险挤出了 6 条上限（2026-09-19 实录）。
    func testWeekLevelIsBoundedAndRankingPrefersNearerDeadlines() {
        let rendered = DailySummaryPromptTemplate.render(for: DailySource.claude)
        XCTAssertTrue(rendered.contains("due within the next 7 days"))
        XCTAssertTrue(rendered.contains("nearest deadline or event time ranks first"))
        XCTAssertFalse(rendered.contains("`week` — a later follow-up"), "旧的含糊定义还在")
    }
}

/// 被条目上限挤掉的事项不能永久丢失。
final class BacklogTests: XCTestCase {
    func testBacklogLivesInDataDirectoryAndIsDistinct() {
        let backlog = DailySummaryPublisher.backlogURL
        XCTAssertTrue(backlog.path.hasPrefix(DailySummaryConstants.dataDirectoryURL.path))
        XCTAssertNotEqual(backlog, DailySummaryPublisher.publishedMirrorURL)
        XCTAssertNotEqual(backlog.lastPathComponent, DailySummaryConstants.summaryFilename)
    }

    /// 提示词必须：读 backlog、把挤掉的写回 backlog、两边一视同仁地重评。
    func testPromptReadsAndWritesBacklog() {
        for source in [DailySource.claude, DailySource.codex] {
            let rendered = DailySummaryPromptTemplate.render(for: source)
            XCTAssertFalse(rendered.contains("<BACKLOG_FILE>"), "来源 \(source) 留着占位符")
            let path = DailySummaryPublisher.backlogURL.path
            XCTAssertGreaterThanOrEqual(
                rendered.components(separatedBy: path).count - 1, 2,
                "来源 \(source) 的提示词里 backlog 路径应当既被读又被写"
            )
            XCTAssertTrue(rendered.contains("treat both exactly the same way"))
        }
    }
}
