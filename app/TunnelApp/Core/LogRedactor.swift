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

struct PrivacyMasker: Sendable {
    private let homePath: String

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        homePath = homeDirectory.standardizedFileURL.path
    }

    func path(_ value: String) -> String {
        value.replacingOccurrences(of: homePath, with: "$HOME")
    }

    func identifier(_ value: String) -> String {
        value.isEmpty ? "—" : "••••••••"
    }

    func yaml(_ value: String) -> String {
        let redacted = SensitiveLogRedactor().redact(path(value))
        let definitions: [(String, String)] = [
            (#"(?m)^(\s*tunnel:\s*).+$"#, "$1<已隐藏隧道 ID>"),
            (#"(?m)^(\s*credentials-file:\s*).+$"#, "$1<已隐藏凭据路径>"),
            (#"(?m)^(\s*-?\s*hostname:\s*).+$"#, "$1<已隐藏域名>"),
            (#"(?m)^([ \t]*-?[ \t]*service:[ \t]*)(?![ \t]*['\"]?http_status:).+$"#, "$1<已隐藏服务>")
        ]
        return definitions.reduce(redacted) { text, definition in
            guard let expression = try? NSRegularExpression(pattern: definition.0) else { return text }
            return expression.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: definition.1
            )
        }
    }
}
