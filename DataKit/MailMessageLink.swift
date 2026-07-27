// MailMessageLink.swift
// DataKit — `message://` 深链的构造。
//
// 从 MailWidgetExtension 的 MailDeepLink 抽到这里，因为宿主 app 的日报详细页面
// 也要用同一套规则。这段编码规则踩过坑（把 `@` 一起编码掉会让深链静默失效），
// 复制成两份迟早会漂移，所以只保留一份实现，MailDeepLink 转调它。

import Foundation

enum MailMessageLink {
    /// 只对真正会破坏 URL 的字符做百分号编码。`@ . + $` 都是合法且常见的
    /// Message-ID 字符，必须原样保留 —— 把 `@` 编码掉正是之前深链失效的原因。
    private static let allowedCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~!$&'()*+,;=@")
        return set
    }()

    /// `message://<Message-ID>`：双斜杠是社区验证过的稳定形式，单斜杠在某些
    /// Mail.app 版本上会静默无操作。`messageIdHeader` 不含尖括号；Mail 要求它们
    /// 以 `%3C`/`%3E` 的形式出现。
    static func url(forMessageIdHeader messageIdHeader: String) -> URL? {
        guard let encoded = messageIdHeader.addingPercentEncoding(
            withAllowedCharacters: allowedCharacters
        ) else {
            return nil
        }
        return URL(string: "message://%3C\(encoded)%3E")
    }
}
