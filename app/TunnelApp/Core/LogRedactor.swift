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
            (#"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s,;]+"#, "$1<已隐藏>"),
            (#"(?i)((?:tunnel[_-]?token|token)\s*[:=]\s*)[^\s,;]+"#, "$1<已隐藏>"),
            (#"(?i)(--token(?:=|\s+))[^\s]+"#, "$1<已隐藏>"),
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
