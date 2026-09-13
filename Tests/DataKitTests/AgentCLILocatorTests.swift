// AgentCLILocatorTests.swift
// DataKitTests — 文件存在 ≠ 能用（真机部署实录：codex 0.137 文件在，一跑 `exec` 就因为
// 模型版本不兼容崩溃，而旧的 `isInstalled` 只检查文件存不存在）。
//
// 只测 `probeUnusableReason(executablePath:cliDisplayName:timeout:)` 这个不经过 App
// Group 缓存/真实候选路径扫描的探测本体——`unusableReason(for:)` 会读写
// `UserDefaults(suiteName: SharedConstants.appGroupIdentifier)`，在这台机器上是可用的
// （不像 App Group 容器文件那样需要 entitlement），但直接测探测本体不依赖这一层，
// 断言意图更直接。

import XCTest
import Foundation

final class AgentCLILocatorTests: XCTestCase {

    func testMissingExecutableReturnsAReason() {
        let reason = AgentCLILocator.probeUnusableReason(
            executablePath: "/definitely/does/not/exist/xyz-codex",
            cliDisplayName: "codex"
        )
        XCTAssertNotNil(reason, "不存在的可执行文件必须返回一个原因，不能是 nil（可用）")
        XCTAssertTrue(reason?.contains("codex") == true, "原因文案应该点名是哪个 CLI：\(reason ?? "<nil>")")
    }

    func testNilPathReturnsAReason() {
        let reason = AgentCLILocator.probeUnusableReason(executablePath: nil, cliDisplayName: "claude")
        XCTAssertNotNil(reason)
    }

    func testExecutableThatExitsZeroIsUsable() {
        // /usr/bin/true 忽略所有参数、总是退出码 0 —— 等价于"CLI --version 正常返回"。
        let reason = AgentCLILocator.probeUnusableReason(executablePath: "/usr/bin/true", cliDisplayName: "codex")
        XCTAssertNil(reason, "退出码 0 应该判定为可用（nil），实际返回了：\(reason ?? "<nil>")")
    }

    func testExecutableThatExitsNonZeroIsUnusable() {
        // /usr/bin/false 总是退出码 1 —— 模拟"--version 也跑不起来"的坏 CLI。
        let reason = AgentCLILocator.probeUnusableReason(executablePath: "/usr/bin/false", cliDisplayName: "codex")
        XCTAssertNotNil(reason, "非零退出码必须判定为不可用")
    }

    func testHangingProcessTimesOut() {
        // /usr/bin/yes 会无视 --version 参数、无限产出直到管道写满而阻塞——用极短的超时
        // （1 秒）验证看门狗真的会 terminate() 它，而不是把测试挂死。
        let start = Date()
        let reason = AgentCLILocator.probeUnusableReason(
            executablePath: "/usr/bin/yes",
            cliDisplayName: "codex",
            timeout: 1
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotNil(reason, "超时必须判定为不可用")
        XCTAssertTrue(reason?.contains("超时") == true, "超时原因文案应该说明是超时：\(reason ?? "<nil>")")
        XCTAssertLessThan(elapsed, 10, "看门狗应该在远小于 10 秒内终止挂死的进程")
    }
}
