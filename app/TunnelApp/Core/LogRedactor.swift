import Foundation

protocol LogRedacting: Sendable {
    func redact(_ text: String) -> String
}

struct SensitiveLogRedactor: LogRedacting {
    private struct Rule: @unchecked Sendable {
        let expression: NSRegularExpression
        let template: String
    }

    private let rules: [Rule]

    init() {
        let home = NSRegularExpression.escapedPattern(
            for: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        )
        let definitions: [(String, String)] = [
            (
                #"(?im)^([ \t]*(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|cf-access-client-secret)[ \t]*:[ \t]*)[^\r\n]*"#,
                "$1<已隐藏>"
            ),
            (
                #"(?i)(\"(?:tunnel[_-]?token|access[_-]?token|api[_-]?token|token|client[_-]?secret|password|passwd|api[_-]?key|x-api-key|cf-access-client-secret|authorization|proxy-authorization|cookie|set-cookie)\"\s*:\s*)\[[^\]\r\n]*\]"#,
                "$1[\"<已隐藏>\"]"
            ),
            (
                #"(?i)(\"(?:tunnel[_-]?token|access[_-]?token|api[_-]?token|token|client[_-]?secret|password|passwd|api[_-]?key|x-api-key|cf-access-client-secret|authorization|proxy-authorization|cookie|set-cookie)\"\s*:\s*)\"(?:\\.|[^\"\\])*\""#,
                "$1\"<已隐藏>\""
            ),
            (
                #"(?i)(--(?:tunnel-?token|access-token|api-token|token|client-secret|password|api-key)(?:=|\s+))(?:\"(?:\\.|[^\"\\])*\"|'[^'\r\n]*'|[^\s,;&]+)"#,
                "$1<已隐藏>"
            ),
            (
                #"(?i)(\b(?:authorization|proxy-authorization)\s*[:=]\s*(?:bearer|basic)\s+)(?:\"(?:\\.|[^\"\\])*\"|'[^'\r\n]*'|[^\s,;&]+)"#,
                "$1<已隐藏>"
            ),
            (
                #"(?i)(\b(?:tunnel[_-]?token|access[_-]?token|api[_-]?token|token|client[_-]?secret|password|passwd|api[_-]?key|x-api-key|cf-access-client-secret|authorization|proxy-authorization|cookie|set-cookie)\b\s*[:=]\s*)(?:\"(?:\\.|[^\"\\])*\"|'[^'\r\n]*'|[^\s,;&]+)"#,
                "$1<已隐藏>"
            ),
            (#"\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]{8,})?\b"#, "<令牌已隐藏>"),
            ("\(home)(?=/|\\b)", "\\$HOME")
        ]

        rules = definitions.compactMap { pattern, template in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Rule(expression: expression, template: template)
        }
    }

    func redact(_ text: String) -> String {
        rules.reduce(text) { value, rule in
            rule.expression.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..., in: value),
                withTemplate: rule.template
            )
        }
    }
}
