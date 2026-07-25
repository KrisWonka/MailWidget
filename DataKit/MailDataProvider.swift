// MailDataProvider.swift
// DataKit — 数据源协议 + 选择器 + 契约 7 的权限诊断 API。
// 运行时按授权状态选择：EnvelopeIndexProvider（主）可用即用，否则降级 AppleScriptProvider（兜底）。

import Foundation

/// 数据源抽象：负责一次性抓取全部账户/邮箱/邮件，产出 MailSnapshot。
protocol MailDataProvider {
    func fetchSnapshot() throws -> MailSnapshot
}

/// 契约 7 — 权限诊断报告，供 frontend 设置页展示。
struct ProbeReport {
    let envelopeIndexAvailable: Bool
    let envelopeIndexDetail: String
    /// "envelopeIndex" | "appleScript" — 当前会被选中使用的数据源。
    let activeProvider: String
}

/// 契约 7 — 权限诊断 API。
enum ProviderProbe {
    static func run() -> ProbeReport {
        do {
            _ = try EnvelopeIndexProvider()
            return ProbeReport(
                envelopeIndexAvailable: true,
                envelopeIndexDetail: "Envelope Index reachable, required tables/columns present.",
                activeProvider: "envelopeIndex"
            )
        } catch {
            return ProbeReport(
                envelopeIndexAvailable: false,
                envelopeIndexDetail: String(describing: error),
                activeProvider: "appleScript"
            )
        }
    }
}

/// 数据源选择器：Envelope 通道可用（能成功打开且 schema 校验通过）即用，否则降级 AppleScript。
enum MailDataProviderFactory {
    static func makeActiveProvider() -> MailDataProvider {
        if let envelopeProvider = try? EnvelopeIndexProvider() {
            return envelopeProvider
        }
        return AppleScriptProvider()
    }
}
