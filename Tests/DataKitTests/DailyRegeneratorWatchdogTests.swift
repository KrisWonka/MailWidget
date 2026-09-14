import Foundation
import XCTest

/// 2026-09-14：手动「立即刷新」这条路径与 launchd 那条长期不同构，这里把差异钉死。
final class DailyRegeneratorWatchdogTests: XCTestCase {

    // MARK: - 参数与 launchd 路径对齐

    /// `--permission-mode auto` 2026-08-25 因 launchd 任务卡死近 3 小时而加过一次，但只加在
    /// 了 launchd 路径；手动这条从功能引入起一直缺着。缺它在原作者本机不复现（个人
    /// settings 的放行规则恰好盖住），换台机器就会中招——所以必须由测试而不是由运气保证。
    func testClaudeArgumentsCarryAutoPermissionMode() {
        let arguments = DailyRegenerator.argumentsForTesting(source: DailySource.claude, prompt: "PROMPT")
        XCTAssertEqual(arguments, ["-p", "--permission-mode", "auto", "PROMPT"])
    }

    /// codex 走的是 `exec`，权限模型不同，不该被上面那条顺手改坏。
    func testCodexArgumentsUnchanged() {
        let arguments = DailyRegenerator.argumentsForTesting(source: DailySource.codex, prompt: "PROMPT")
        XCTAssertEqual(arguments, ["exec", "--skip-git-repo-check", "PROMPT"])
    }

    // MARK: - 看门狗与 flag 过期的不变式

    /// 关键不变式：flag 过期 ⇒ 进程已被杀死。看门狗必须严格早于 `staleAfter` 触发，
    /// 否则一次跑满 15 分钟的运行会让 flag 先过期，用户再点一次就并发起第二个 agent，
    /// 两个 agent 同时往同一个 latest.json 写。
    func testWatchdogFiresStrictlyBeforeFlagGoesStale() {
        XCTAssertLessThan(DailyRegenerator.watchdogTimeout, DailyRegenerator.staleAfter)
        XCTAssertGreaterThan(DailyRegenerator.watchdogTimeout, 0)
    }

    /// 实测一次正常运行 4 分 46 秒，看门狗不能比这紧。
    func testWatchdogLeavesRoomForARealRun() {
        XCTAssertGreaterThan(DailyRegenerator.watchdogTimeout, 10 * 60)
    }

    // MARK: - 杀进程的目标选择

    /// `Process` 默认不给子进程单独开进程组，子进程的 pgid 通常等于宿主 app 的 pgid。
    /// 此时若无条件 `kill(-pgid)`，会把宿主 app 自己一起杀掉——这条是防这个的。
    func testSharedProcessGroupKillsOnlyTheChild() {
        let target = DailyRegenerator.terminationTarget(childPID: 4321, childPGID: 1000, ownPGID: 1000)
        XCTAssertEqual(target, .singleProcess(4321))
    }

    /// 子进程自成一组时才可以连整组一起杀——agent 会 fork 出 MCP 服务器和 Bash 子进程，
    /// 只杀直接子进程会留下继续跑的孙子进程。
    func testOwnProcessGroupKillsWholeGroup() {
        let target = DailyRegenerator.terminationTarget(childPID: 4321, childPGID: 4321, ownPGID: 1000)
        XCTAssertEqual(target, .processGroup(4321))
    }

    /// 边界：pgid == pid 但恰好也等于自己的 pgid（宿主 app 自己就是组长）——仍然不能按组杀。
    func testChildIsGroupLeaderOfOurOwnGroupStillKillsOnlyTheChild() {
        let target = DailyRegenerator.terminationTarget(childPID: 1000, childPGID: 1000, ownPGID: 1000)
        XCTAssertEqual(target, .singleProcess(1000))
    }
}

/// 2026-09-14 codex 复查发现：这个登录 shell 探测没有超时，而同仓库里性质相同的
/// `AgentCLILocator.probeVersion` 有 15 秒看门狗。它跑在 spawn agent 之前，卡住就是 app 转圈。
final class AgentRuntimePathTimeoutTests: XCTestCase {
    func testLoginShellProbeHasABoundedTimeout() {
        XCTAssertGreaterThan(AgentRuntimePath.loginShellProbeTimeout, 0)
        XCTAssertLessThanOrEqual(AgentRuntimePath.loginShellProbeTimeout, 30)
    }

    /// 真正的证明：探测一个不存在的命令必须在超时之内返回，而不是无限等。
    func testProbeReturnsPromptlyForMissingTool() {
        let started = Date()
        let result = AgentRuntimePath.resolveViaLoginShell("definitely-not-a-real-command-xyz")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, AgentRuntimePath.loginShellProbeTimeout + 5)
    }
}
