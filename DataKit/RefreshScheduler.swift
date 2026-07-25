// RefreshScheduler.swift
// DataKit — 契约 6：定时抓取 + reloadAllTimelines。
// start() 由宿主 app 启动时调用；refreshNow() 供菜单栏"立即刷新"，返回是否成功；
// 成功后内部负责 WidgetCenter.reloadAllTimelines()。
//
// 事件驱动刷新（契约 10，2026-07-23 新增，用户反馈"点进 Mail 读完信 widget 蓝点还在，
// 要等 2 分钟轮询"）：额外监听 Envelope Index 的 WAL 文件（Mail 读/写状态变化会写它），
// 命中就 debounce 3 秒后触发一次和定时刷新一样的抓取+save+reload；Mail 写库很频繁，
// 不 debounce 会刷屏式地反复抓取。只有 Envelope 通道当前可用才装（AppleScript 兜底
// 通道没有本地文件可看，不装）。WAL 文件在 checkpoint 时会被删除/重命名重建，监听到
// DELETE/RENAME 就重新 open 一个新 fd 重新挂（带几次重试余地）。

import Foundation
import WidgetKit
#if canImport(AppKit)
import AppKit
#endif

/// 简单的"最后一次赢"防抖器：短时间内连续调用 schedule() 只会在停下来的 delay 秒后
/// 执行最后一次 action；每次新调用都会取消上一次还没触发的 pending 调用。跟 Envelope
/// 文件监听解耦成独立的小单元，方便单独用 harness/单测验证防抖本身（不用真的开文件
/// 监听、不用等 Mail 写库）。
final class Debouncer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var pendingWorkItem: DispatchWorkItem?

    init(delay: TimeInterval, queue: DispatchQueue = .global(qos: .utility)) {
        self.delay = delay
        self.queue = queue
    }

    func schedule(_ action: @escaping () -> Void) {
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem(block: action)
        pendingWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

final class RefreshScheduler {

    static let shared = RefreshScheduler()

    private var timer: Timer?
    #if canImport(AppKit)
    private var wakeObserver: NSObjectProtocol?
    #endif
    private var envelopeWatcher: DispatchSourceFileSystemObject?
    private let envelopeDebouncer = Debouncer(delay: 3.0)

    private init() {}

    /// 启动定时刷新（Timer，间隔读共享 UserDefaults）+ 系统唤醒触发 + Envelope 文件变化
    /// 触发（仅 Envelope 通道当前可用时）。可重复调用（幂等）。
    func start() {
        scheduleTimer()
        #if canImport(AppKit)
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.refreshNow()
            }
        }
        #endif
        startWatchingEnvelopeChanges { [weak self] in
            Task { [weak self] in
                await self?.refreshNow()
            }
        }
    }

    /// 立即刷新一次：抓取快照、落盘、成功则 reloadAllTimelines。返回是否成功。
    @discardableResult
    func refreshNow() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var success = false
                do {
                    let provider = MailDataProviderFactory.makeActiveProvider()
                    let snapshot = try provider.fetchSnapshot()
                    try SnapshotStore.save(snapshot)
                    success = true
                } catch {
                    success = false
                }
                if success {
                    WidgetCenter.shared.reloadAllTimelines()
                }
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Envelope 文件监听（可测试入口）

    /// 尝试挂载 Envelope Index 的 WAL 文件监听；`onChange` 是 debounce（3 秒）命中后
    /// 执行的动作。返回是否真的挂上了（Envelope 通道当前不可用——比如没有完全磁盘访问
    /// 权限、或压根没有 Mail 数据——就直接返回 false，不装监听，交给 2 分钟定时器兜底）。
    ///
    /// 特意不声明成 private：让 harness/单测能直接调它、传一个"只打印时间戳"的
    /// onChange，用来验证监听链路本身通不通，不用每次都触发一遍完整的抓取+落盘+reload。
    @discardableResult
    func startWatchingEnvelopeChanges(onChange: @escaping () -> Void) -> Bool {
        teardownEnvelopeWatcher()
        guard let provider = try? EnvelopeIndexProvider() else {
            return false
        }
        let walURL = provider.mailDataDirectoryURL.appendingPathComponent("Envelope Index-wal")
        return installWatcher(forFileAt: walURL, onChange: onChange, retriesLeftOnReopen: 3)
    }

    @discardableResult
    private func installWatcher(forFileAt url: URL, onChange: @escaping () -> Void, retriesLeftOnReopen: Int) -> Bool {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        // 弱引用 source 自己，避免"闭包被 source 持有 + 闭包又强引用 source"的自环，
        // source 的唯一强引用应该只来自 self.envelopeWatcher 这一处。
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // WAL checkpoint 把文件删了/重建了：这个 fd 指向的已经是"死"文件，
                // 重新 open 一个新 fd 挂到（重建后的）新文件上；checkpoint 后文件
                // 重新出现通常是瞬间的事，留几次重试余地。
                self.teardownEnvelopeWatcher()
                if retriesLeftOnReopen > 0 {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                        _ = self.installWatcher(forFileAt: url, onChange: onChange, retriesLeftOnReopen: retriesLeftOnReopen - 1)
                    }
                }
                return
            }
            self.envelopeDebouncer.schedule(onChange)
        }
        source.setCancelHandler {
            close(fd)
        }
        envelopeWatcher = source
        source.resume()
        return true
    }

    private func teardownEnvelopeWatcher() {
        envelopeWatcher?.cancel()
        envelopeWatcher = nil
    }

    // MARK: - Private（定时器）

    private func currentIntervalSeconds() -> TimeInterval {
        let defaults = UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
        let stored = defaults?.double(forKey: SharedConstants.refreshIntervalMinutesKey) ?? 0
        let minutes = stored > 0 ? stored : SharedConstants.defaultRefreshIntervalMinutes
        return minutes * 60
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = currentIntervalSeconds()
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 用户可能在两次 tick 之间改了刷新间隔；发现变化就重新调度定时器。
            if self.currentIntervalSeconds() != interval {
                self.scheduleTimer()
            }
            Task { [weak self] in
                await self?.refreshNow()
            }
        }
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }
}
