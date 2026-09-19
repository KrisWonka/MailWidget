import Foundation
import XCTest

/// 多日模拟：把一周的真实使用在几秒钟里快进演一遍，每一轮之后检查几条必须一直成立的规则。
///
/// ## 为什么要有它
///
/// 2026-09-13 到 09-19 连续撞了四次线上 bug。每一次单看"跑一次对不对"都是对的，单元测试也
/// 全绿；坏掉的都是**时间一长、同一个操作做两次**之后才出现的行为：
///   - 09-14：刚跑完再点一次刷新，零新邮件 → 发了空日报 → 待办被清空
///   - 09-19：日报按游标增量检索、又整份替换，新邮件一来就把还没到期的事项冲掉；于是
///            不敢多跑，只能一天一次，白天到的邮件要等到第二天
/// 这两个在这里演一遍就会当场失败（见 `testLegacyContractIsCaughtByTheInvariants`）。
///
/// ## 什么是真的、什么是假的
///
/// - **真的**：`DailySummaryPublisher.publishCore`（新鲜度判定、零条目守门、落盘、写镜像）、
///   `DailySummaryStore`、编码校验。生产环境里 `--ingest` 走的就是这同一段代码。
/// - **假的**：邮箱（一张带到达时间和截止日的邮件表）、时钟（可以快进）、agent（一个严格照
///   提示词契约办事的确定性实现，不调用真的 Claude、不花额度）。
///
/// 所以它测的是**整条链路和契约在时间上的行为**，测不了"AI 判断错了哪封重要"。
///
/// ## 隔离
///
/// 全部读写都在临时目录里，**绝不碰用户真实的 widget 数据**——一次模拟要发布几十轮。
/// 唯一与真实状态有关的是邮箱：`save` 会触发校验，而校验在"尚未配置邮箱"时会把载荷里的
/// 邮箱**自动写进真实配置**（首次投递自动认领）。所以这里只用已经配置好的那个邮箱，读不到
/// 就跳过，绝不触发那次写入。
final class DailyBriefSimulationTests: XCTestCase {

    // MARK: - 假邮箱

    enum Kind {
        /// 需要回复。回复发出后就算办完。
        case reply
        /// 需要做某件事，通常有截止日。
        case action
        /// 可做可不做（活动、机会）。
        case optional
        /// 纯通知，不需要动作。
        case info
    }

    struct Mail {
        let id: String
        let title: String
        let kind: Kind
        let arrives: Date
        let deadline: Date?
        /// 用户什么时候回复了这封（只对 `.reply` 有意义）。
        var repliedAt: Date?

        /// 事实上是否仍然未办完——这是检查规则用的**标准答案**，与 agent 怎么判断无关。
        func isOpen(at now: Date) -> Bool {
            guard arrives <= now else { return false }
            if let deadline, deadline <= now { return false }
            if kind == .reply, let repliedAt, repliedAt <= now { return false }
            return true
        }
    }

    // MARK: - 世界

    final class World {
        var mails: [Mail]
        let directory: URL
        let store: DailySummaryStore
        let mailbox: String
        var cursor: Date?
        var now: Date

        var mirrorURL: URL { directory.appendingPathComponent("published.json") }
        var backlogURL: URL { directory.appendingPathComponent("backlog.json") }

        init(mails: [Mail], start: Date, mailbox: String) throws {
            self.mails = mails
            self.now = start
            self.mailbox = mailbox
            self.directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("brief-sim-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.store = DailySummaryStore(containerURL: directory.appendingPathComponent("group"))
        }

        func mail(_ id: String) -> Mail? { mails.first { $0.id == id } }

        /// widget 上实际显示的——检查规则用这个。
        var widget: [DailySummaryItem] { (try? store.load())?.items ?? [] }

        /// agent 读到的"当前日报"——**必须读镜像文件，不能读存储本身**。真 agent 读的就是
        /// `published.json`；假 agent 若直接读存储，镜像哪天写坏了模拟也照样全绿，等于没测
        /// 那条路径（第一版就是这么写的，审查时发现后改掉）。
        var publishedAsAgentSeesIt: [DailySummaryItem] {
            guard let data = try? Data(contentsOf: mirrorURL) else { return [] }
            return (try? JSONDecoder().decode(DailySummary.self, from: data))?.items ?? []
        }

        var backlog: [DailySummaryItem] {
            guard let data = try? Data(contentsOf: backlogURL) else { return [] }
            return (try? JSONDecoder().decode([DailySummaryItem].self, from: data)) ?? []
        }

        func gmailURL(for id: String) -> URL {
            var components = URLComponents(string: "https://mail.google.com/mail/u/0/")!
            components.queryItems = [URLQueryItem(name: "authuser", value: mailbox)]
            components.fragment = "all/\(id)"
            return components.url!
        }

        func publish(_ items: [DailySummaryItem], runStartedAt: Date) {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            let summary = DailySummary(
                schemaVersion: 1,
                mailbox: mailbox,
                generatedAt: formatter.string(from: now),
                headline: items.isEmpty ? "暂无需要处理的邮件。" : "模拟日报",
                items: items
            )
            // 与生产环境同一段代码。守门拒收时抛错——那不是失败，widget 保持原样，
            // 正是生产环境里会发生的事。
            try? DailySummaryPublisher.publishCore(
                summary,
                payloadModifiedAt: now,
                notBefore: runStartedAt,
                context: .init(store: store, mirrorURL: mirrorURL, now: now)
            )
        }
    }

    // MARK: - 分级与排序（照提示词 Classification 一节）

    static func level(of mail: Mail, at now: Date) -> DailySummaryLevel {
        switch mail.kind {
        case .info:
            return .info
        case .optional:
            return .optional
        case .reply, .action:
            guard let deadline = mail.deadline else {
                return mail.kind == .reply ? .today : .week
            }
            let remaining = deadline.timeIntervalSince(now)
            if remaining <= 24 * 3600 { return .immediate }
            if remaining <= 7 * 24 * 3600 { return .week }
            // 提示词：7 天以外的截止日在临近之前按 info 处理，不占近期事项的位子。
            return .info
        }
    }

    static let levelRank: [DailySummaryLevel: Int] = [
        .immediate: 0, .today: 1, .week: 2, .optional: 3, .info: 4,
    ]

    /// 同级内截止日越近越靠前，有截止日的优先于没有的；最后按 id 保证确定性。
    static func ranks(_ a: DailySummaryItem, before b: DailySummaryItem, in world: World) -> Bool {
        let (la, lb) = (levelRank[a.level]!, levelRank[b.level]!)
        if la != lb { return la < lb }
        let da = world.mail(a.id)?.deadline ?? .distantFuture
        let db = world.mail(b.id)?.deadline ?? .distantFuture
        if da != db { return da < db }
        return a.id < b.id
    }

    // MARK: - 两个 agent

    /// 严格照**当前**提示词契约办事：增量检索 + 结转已发布与 backlog 里仍有效的 + 合并 +
    /// 排序 + 截到上限 + 挤掉的写回 backlog；零新邮件时照样发结转项。
    static func runCurrentContract(_ world: World) {
        let runStartedAt = world.now
        let since = world.cursor ?? world.now.addingTimeInterval(-24 * 3600)
        let fresh = world.mails.filter { $0.arrives > since && $0.arrives <= world.now }

        // 检索第 5 步：已发布 ∪ backlog，保留仍有效的。
        var candidateIDs = Set<String>()
        for item in world.publishedAsAgentSeesIt + world.backlog {
            if let mail = world.mail(item.id), mail.isOpen(at: world.now) {
                candidateIDs.insert(item.id)
            }
        }
        for mail in fresh where mail.isOpen(at: world.now) {
            candidateIDs.insert(mail.id)
        }

        let candidates = candidateIDs.compactMap { id -> DailySummaryItem? in
            guard let mail = world.mail(id) else { return nil }
            return DailySummaryItem(
                id: mail.id,
                level: level(of: mail, at: world.now),
                title: mail.title,
                detail: mail.title,
                gmailURL: world.gmailURL(for: mail.id)
            )
        }.sorted { ranks($0, before: $1, in: world) }

        let limit = DailySummaryConstants.maximumItemCount
        let kept = Array(candidates.prefix(limit))
        let cut = Array(candidates.dropFirst(limit))

        if let data = try? JSONEncoder().encode(cut) {
            try? data.write(to: world.backlogURL)
        }
        world.publish(kept, runStartedAt: runStartedAt)
        if let newest = fresh.map(\.arrives).max() { world.cursor = newest }
    }

    /// **不听话的 agent**：有新邮件时照契约办，一遇到零新邮件就无视结转、直接发空——
    /// 这正是 09-14 真实发生过的事（真 agent 照着当时的旧规则发了 `items: []`）。
    ///
    /// 为什么需要它：零条目守门是防 agent 犯错的。只用一个永远听话的假 agent，守门根本
    /// 不会被触发——变异测试时把守门整个拿掉，模拟照样全绿（审查时实测发现）。
    static func runForgetfulAgent(_ world: World) {
        let since = world.cursor ?? world.now.addingTimeInterval(-24 * 3600)
        let hasFresh = world.mails.contains { $0.arrives > since && $0.arrives <= world.now }
        guard hasFresh else {
            world.publish([], runStartedAt: world.now)
            return
        }
        runCurrentContract(world)
    }

    /// **09-19 之前**的旧契约：只看游标之后的新邮件、整份替换、零新邮件就发空、没有 backlog。
    /// 留着它是为了证明这套检查真的有牙——旧契约必须在这里被抓出来。
    static func runLegacyContract(_ world: World) {
        let runStartedAt = world.now
        let since = world.cursor ?? world.now.addingTimeInterval(-24 * 3600)
        let fresh = world.mails.filter { $0.arrives > since && $0.arrives <= world.now && $0.isOpen(at: world.now) }
        let items = fresh.map { mail in
            DailySummaryItem(
                id: mail.id,
                level: level(of: mail, at: world.now),
                title: mail.title,
                detail: mail.title,
                gmailURL: world.gmailURL(for: mail.id)
            )
        }.sorted { ranks($0, before: $1, in: world) }
        world.publish(Array(items.prefix(DailySummaryConstants.maximumItemCount)), runStartedAt: runStartedAt)
        if let newest = fresh.map(\.arrives).max() { world.cursor = newest }
    }

    // MARK: - 必须一直成立的规则

    struct Violation: CustomStringConvertible {
        let step: String
        let rule: String
        var description: String { "[\(step)] \(rule)" }
    }

    /// 每一轮之后都检查。返回违反了哪些，调用方决定是断言为空（当前契约）还是断言非空（旧契约）。
    static func check(_ world: World, step: String) -> [Violation] {
        var found: [Violation] = []
        let widget = world.widget
        let widgetIDs = Set(widget.map(\.id))
        let backlogIDs = Set(world.backlog.map(\.id))

        // 规则 1：已经到了、事实上还没办完的事，必须在 widget 或 backlog 里——不能凭空消失。
        for mail in world.mails where mail.isOpen(at: world.now) {
            if !widgetIDs.contains(mail.id) && !backlogIDs.contains(mail.id) {
                found.append(Violation(step: step, rule: "还没办完的「\(mail.title)」从 widget 和 backlog 里都消失了"))
            }
        }

        // 规则 2：widget 上不能出现已经过期或已经办完的事。
        for item in widget {
            if let mail = world.mail(item.id), !mail.isOpen(at: world.now) {
                found.append(Violation(step: step, rule: "已经过期或办完的「\(mail.title)」还挂在 widget 上"))
            }
        }

        // 规则 3：不超过上限。
        if widget.count > DailySummaryConstants.maximumItemCount {
            found.append(Violation(step: step, rule: "widget 上有 \(widget.count) 条，超过上限"))
        }

        // 规则 4：被挤进 backlog 的，不能比留在 widget 上的更要紧。
        if let weakest = widget.max(by: { ranks($0, before: $1, in: world) }) {
            for item in world.backlog where ranks(item, before: weakest, in: world) {
                found.append(Violation(step: step, rule: "「\(item.title)」比 widget 上的「\(weakest.title)」更要紧，却被挤进了 backlog"))
            }
        }
        return found
    }

    // MARK: - 剧本：这一周真实发生过的事

    /// 返回（邮件表，起始时刻，按时间排好的事件）。时间全部用本机日历构造，跨时区跑也一致。
    static func weekScript() -> (mails: [Mail], start: Date, events: [(Date, Event)]) {
        let calendar = Calendar.current
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14))!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(day: day, hour: hour, minute: minute), to: monday)!
        }

        let mails: [Mail] = [
            // 周一早上就在的
            Mail(id: "debbie", title: "回复 ELI 顾问 Debbie", kind: .reply, arrives: at(0, 8), deadline: nil),
            Mail(id: "dental", title: "国际生牙科保险 9/30 截止", kind: .optional, arrives: at(0, 8), deadline: at(16, 23, 59)),
            Mail(id: "training", title: "性骚扰防治培训（明年 4 月前）", kind: .action, arrives: at(0, 8), deadline: at(228, 23, 59)),
            // 周一上午新到——9/19 那次就是它把上面几条冲掉的
            Mail(id: "adddrop", title: "9/21 加退课截止", kind: .action, arrives: at(0, 10, 30), deadline: at(7, 23, 59)),
            // 周一下午一批，凑够超过 6 条上限，逼出 backlog
            Mail(id: "clinic", title: "9/23 15:15 口语诊所", kind: .action, arrives: at(0, 15), deadline: at(9, 15, 15)),
            Mail(id: "catering", title: "周二中午前确认排班", kind: .action, arrives: at(0, 15), deadline: at(1, 12)),
            Mail(id: "handshake", title: "Handshake 实习岗位", kind: .optional, arrives: at(0, 15), deadline: nil),
            Mail(id: "bluecross", title: "蓝十字账户验证", kind: .action, arrives: at(0, 15), deadline: at(5, 17)),
            Mail(id: "f1rule", title: "F-1 新规暂缓通知", kind: .info, arrives: at(0, 15), deadline: nil),
            // 同一批里再来几件近期要办的——真实的开学周就是这么挤。它们都排在牙科保险
            // （optional）前面，把它挤进 backlog；周二到周四陆续到期后腾出位子，它应当回来。
            Mail(id: "hw1", title: "ROB 501 作业一", kind: .action, arrives: at(0, 15), deadline: at(1, 23, 59)),
            Mail(id: "rsvp", title: "迎新晚宴 RSVP", kind: .action, arrives: at(0, 15), deadline: at(2, 12)),
            Mail(id: "form", title: "助教申请表", kind: .action, arrives: at(0, 15), deadline: at(2, 17)),
            Mail(id: "payment", title: "学费分期首付", kind: .action, arrives: at(0, 15), deadline: at(3, 17)),
            // 周三新到
            Mail(id: "advisor", title: "导师约面谈", kind: .reply, arrives: at(2, 11), deadline: at(3, 17)),
        ]

        let scheduled = (0...7).flatMap { day in [at(day, 9, 7), at(day, 13, 7), at(day, 18, 7)] }
        var events: [(Date, Event)] = scheduled.map { ($0, .run) }
        events.append((at(0, 13, 8), .run))            // 刚跑完又点了一下刷新——09-14 就栽在这
        events.append((at(0, 13, 9), .run))            // 再点一下
        events.append((at(1, 11), .reply("debbie")))   // 周二上午回了 Debbie
        events.append((at(3, 10), .reply("advisor")))  // 周四回了导师
        events.sort { $0.0 < $1.0 }
        return (mails, at(0, 0), events)
    }

    enum Event {
        case run
        case reply(String)
    }

    @discardableResult
    static func play(
        _ agent: (World) -> Void,
        mailbox: String,
        onStep: ((World, String) -> Void)? = nil
    ) throws -> (world: World, violations: [Violation]) {
        let script = weekScript()
        let world = try World(mails: script.mails, start: script.start, mailbox: mailbox)
        defer { try? FileManager.default.removeItem(at: world.directory) }

        // 标签必须带日期：剧本跨 8 天，第 0 天和第 7 天都是周一，只写「周一 13:07」会互相
        // 覆盖（第一版就栽在这，连点刷新那条测试拿到的是下周一的快照）。
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d E HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")

        var violations: [Violation] = []
        for (time, event) in script.events {
            world.now = time
            switch event {
            case .reply(let id):
                if let index = world.mails.firstIndex(where: { $0.id == id }) {
                    world.mails[index].repliedAt = time
                }
            case .run:
                agent(world)
                let step = formatter.string(from: time)
                violations += check(world, step: step)
                onStep?(world, step)
            }
        }
        return (world, violations)
    }

    private func configuredMailbox() throws -> String {
        guard let mailbox = DailySummaryConstants.configuredMailbox, !mailbox.isEmpty else {
            throw XCTSkip("没有配置日报邮箱。这里不能自己编一个——校验会把它自动写进真实配置。")
        }
        return mailbox
    }

    // MARK: - 测试

    /// 当前契约演完一整周，每一轮之后所有规则都必须成立。
    func testCurrentContractHoldsAllWeek() throws {
        let (_, violations) = try Self.play(Self.runCurrentContract, mailbox: configuredMailbox())
        XCTAssertTrue(violations.isEmpty, "当前契约在这一周里违反了规则：\n" + violations.map(\.description).joined(separator: "\n"))
    }

    /// 证明这套检查有牙：09-19 之前的旧契约必须在这里被抓出来，而且要抓在对的地方——
    /// 周一 13:07，新邮件一到就把还没到期的事项冲掉。抓不出来说明检查本身是摆设。
    func testLegacyContractIsCaughtByTheInvariants() throws {
        let (_, violations) = try Self.play(Self.runLegacyContract, mailbox: configuredMailbox())
        XCTAssertFalse(violations.isEmpty, "旧契约居然通过了——这套检查抓不住 09-19 那个 bug")
        XCTAssertTrue(
            violations.contains { $0.step.hasPrefix("9/14") && $0.step.hasSuffix("13:07") && $0.rule.contains("消失") },
            "应当在周一 13:07 抓到『还没办完的事消失了』，实际抓到的是：\n" + violations.map(\.description).joined(separator: "\n")
        )
    }

    /// 连点刷新：两次之间没有新邮件、没有到期、没有回复，widget 必须原样不动。
    /// 09-14 那次就是刚跑完再点一下，结果整份被清空。
    func testRepeatedRefreshLeavesTheBriefUnchanged() throws {
        var snapshots: [String: [String]] = [:]
        try Self.play(Self.runCurrentContract, mailbox: configuredMailbox()) { world, step in
            snapshots[step] = world.widget.map(\.id).sorted()
        }
        let monday = snapshots.keys.filter { $0.hasPrefix("9/14") }
        let at1307 = monday.first { $0.hasSuffix("13:07") }.flatMap { snapshots[$0] }
        let at1308 = monday.first { $0.hasSuffix("13:08") }.flatMap { snapshots[$0] }
        let at1309 = monday.first { $0.hasSuffix("13:09") }.flatMap { snapshots[$0] }
        XCTAssertNotNil(at1307)
        XCTAssertFalse(at1307?.isEmpty ?? true, "13:07 那一轮之后 widget 不该是空的")
        XCTAssertEqual(at1307, at1308, "连点第一次刷新，widget 变了")
        XCTAssertEqual(at1308, at1309, "连点第二次刷新，widget 变了")
    }

    /// 有新邮件进来，日报就必须变——一整天不动的日报和坏了没有区别（09-19 用户原话：
    /// 「mailwidget 又不更新了」）。
    func testNewMailShowsUpBeforeTheNextMorning() throws {
        var seenAddDropOnMonday = false
        try Self.play(Self.runCurrentContract, mailbox: configuredMailbox()) { world, step in
            if step.hasPrefix("9/14"), world.widget.contains(where: { $0.id == "adddrop" }) {
                seenAddDropOnMonday = true
            }
        }
        XCTAssertTrue(seenAddDropOnMonday, "周一 10:30 到的加退课截止，当天就该出现在 widget 上")
    }

    /// 零条目守门必须挡住不听话的 agent：同一天里刚跑完再点刷新，它发来空日报，widget
    /// 必须原样不动。（守门只管同一个自然日——新的一天发空日报是允许的，所以这里只看
    /// 周一 13:07 之后同一天的两次连点。）
    func testGuardHoldsAgainstAnAgentThatPublishesEmpty() throws {
        var snapshots: [String: [String]] = [:]
        try Self.play(Self.runForgetfulAgent, mailbox: configuredMailbox()) { world, step in
            snapshots[step] = world.widget.map(\.id).sorted()
        }
        let first = snapshots.first { $0.key.hasPrefix("9/14") && $0.key.hasSuffix("13:07") }?.value
        let refreshed = snapshots.first { $0.key.hasPrefix("9/14") && $0.key.hasSuffix("13:08") }?.value
        XCTAssertFalse(first?.isEmpty ?? true, "13:07 那一轮之后 widget 不该是空的")
        XCTAssertEqual(first, refreshed, "agent 发来空日报，守门没挡住——widget 被清空了（09-14 那个 bug）")
    }

    /// 回复之后那条要下去；截止日过了那条也要下去。
    func testDoneAndExpiredItemsLeave() throws {
        let (world, _) = try Self.play(Self.runCurrentContract, mailbox: configuredMailbox())
        let ids = Set(world.widget.map(\.id))
        XCTAssertFalse(ids.contains("debbie"), "周二已经回复了 Debbie，周末还挂着")
        XCTAssertFalse(ids.contains("catering"), "周二中午的排班截止早就过了，还挂着")
        XCTAssertFalse(ids.contains("adddrop"), "9/21 的加退课截止过了，还挂着")
    }

    /// 被上限挤掉的事项不能永久丢失：牙科保险周一被挤进 backlog，等前面的事项陆续办完/
    /// 过期腾出位子，它必须回到 widget 上（09-19 实录：它被挤掉后就彻底消失了）。
    func testCrowdedOutItemComesBackWhenThereIsRoom() throws {
        var wasCrowdedOut = false
        var cameBack = false
        try Self.play(Self.runCurrentContract, mailbox: configuredMailbox()) { world, _ in
            let onWidget = world.widget.contains { $0.id == "dental" }
            let inBacklog = world.backlog.contains { $0.id == "dental" }
            if inBacklog { wasCrowdedOut = true }
            if wasCrowdedOut && onWidget { cameBack = true }
        }
        XCTAssertTrue(wasCrowdedOut, "剧本本意是让牙科保险被挤出去一次，结果没有——剧本需要调整")
        XCTAssertTrue(cameBack, "牙科保险被挤进 backlog 之后再也没回到 widget")
    }
}
