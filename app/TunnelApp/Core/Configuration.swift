import Foundation

struct IngressRule: Identifiable, Equatable, Sendable {
    let id: UUID
    var hostname: String?
    var path: String?
    var service: String
    var preservedLines: [String]
    var hostnameComment: String?
    var pathComment: String?
    var serviceComment: String?

    init(
        id: UUID = UUID(),
        hostname: String? = nil,
        path: String? = nil,
        service: String,
        preservedLines: [String] = [],
        hostnameComment: String? = nil,
        pathComment: String? = nil,
        serviceComment: String? = nil
    ) {
        self.id = id
        self.hostname = hostname
        self.path = path
        self.service = service
        self.preservedLines = preservedLines
        self.hostnameComment = hostnameComment
        self.pathComment = pathComment
        self.serviceComment = serviceComment
    }

    var isCatchAll: Bool {
        Self.normalized(hostname) == nil && Self.normalized(path) == nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct ConfigValidationIssue: Identifiable, Equatable, Sendable {
    enum Severity: String, Sendable {
        case warning
        case error
    }

    let id = UUID()
    let severity: Severity
    let message: String
    let ruleID: UUID?
}

struct CloudflaredConfigDocument: Equatable, Sendable {
    var sourceURL: URL?
    var tunnel: String?
    var credentialsFile: String?
    var ingress: [IngressRule]

    fileprivate var prefixLines: [String]
    fileprivate var suffixLines: [String]
    fileprivate var ingressLeadingLines: [String]
    fileprivate var ingressHeaderLine: String
    fileprivate var ingressRuleIndent: Int
    fileprivate var originalTunnel: String?
    var sourceSnapshot: ConfigurationSourceSnapshot?

    var primaryIngressRule: IngressRule? {
        ingress.first(where: { !$0.isCatchAll })
    }

    init(
        sourceURL: URL? = nil,
        tunnel: String? = nil,
        credentialsFile: String? = nil,
        ingress: [IngressRule],
        prefixLines: [String] = [],
        suffixLines: [String] = [],
        ingressLeadingLines: [String] = [],
        ingressHeaderLine: String = "ingress:",
        ingressRuleIndent: Int = 2,
        sourceSnapshot: ConfigurationSourceSnapshot? = nil
    ) {
        self.sourceURL = sourceURL
        self.tunnel = tunnel
        self.credentialsFile = credentialsFile
        self.ingress = ingress
        self.prefixLines = prefixLines
        self.suffixLines = suffixLines
        self.ingressLeadingLines = ingressLeadingLines
        self.ingressHeaderLine = ingressHeaderLine
        self.ingressRuleIndent = ingressRuleIndent
        originalTunnel = tunnel
        self.sourceSnapshot = sourceSnapshot
    }

    mutating func upsert(hostname: String, path: String? = nil, service: String) {
        let cleanHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanService = service.trimmingCharacters(in: .whitespacesAndNewlines)

        if let index = ingress.firstIndex(where: {
            $0.hostname?.caseInsensitiveCompare(cleanHostname) == .orderedSame &&
            ($0.path ?? "") == (cleanPath ?? "")
        }) {
            ingress[index].hostname = cleanHostname
            ingress[index].path = cleanPath?.isEmpty == true ? nil : cleanPath
            ingress[index].service = cleanService
            return
        }

        let newRule = IngressRule(
            hostname: cleanHostname,
            path: cleanPath?.isEmpty == true ? nil : cleanPath,
            service: cleanService
        )
        if let catchAllIndex = ingress.firstIndex(where: \.isCatchAll) {
            ingress.insert(newRule, at: catchAllIndex)
        } else {
            ingress.append(newRule)
            ingress.append(IngressRule(service: "http_status:404"))
        }
    }

    func validationIssues() -> [ConfigValidationIssue] {
        var issues: [ConfigValidationIssue] = []

        if ingress.isEmpty {
            issues.append(ConfigValidationIssue(
                severity: .error,
                message: "至少需要一条 ingress 规则。",
                ruleID: nil
            ))
            return issues
        }

        for (index, rule) in ingress.enumerated() {
            let service = rule.service.trimmingCharacters(in: .whitespacesAndNewlines)
            if service.isEmpty {
                issues.append(ConfigValidationIssue(
                    severity: .error,
                    message: "第 \(index + 1) 条规则需要设置 service。",
                    ruleID: rule.id
                ))
            }

            if let hostname = rule.hostname?.trimmingCharacters(in: .whitespacesAndNewlines),
               !hostname.isEmpty,
               hostname.contains("://") || hostname.contains(where: \.isWhitespace) {
                issues.append(ConfigValidationIssue(
                    severity: .error,
                    message: "hostname 不能包含 URL 协议或空格。",
                    ruleID: rule.id
                ))
            }

            if rule.isCatchAll && index != ingress.index(before: ingress.endIndex) {
                issues.append(ConfigValidationIssue(
                    severity: .error,
                    message: "兜底规则必须位于最后。",
                    ruleID: rule.id
                ))
            }
        }

        if !ingress.last!.isCatchAll {
            issues.append(ConfigValidationIssue(
                severity: .error,
                message: "最后一条 ingress 规则必须是兜底 service。",
                ruleID: ingress.last?.id
            ))
        }
        return issues
    }
}

enum ConfigParsingError: LocalizedError, Equatable {
    case missingIngress
    case malformedIngress(String)

    var errorDescription: String? {
        switch self {
        case .missingIngress:
            return "此配置中没有 ingress 部分。"
        case let .malformedIngress(message):
            return "无法读取 ingress 部分：\(message)"
        }
    }
}

private enum YAMLTopLevelScalarLine {
    static func rawValue(for key: String, in line: String) -> String? {
        guard line.first?.isWhitespace != true else { return nil }

        for spelling in [key, "'\(key)'", "\"\(key)\""] where line.hasPrefix(spelling) {
            let remainder = line.dropFirst(spelling.count)
            let colon = remainder.drop(while: { $0 == " " || $0 == "\t" })
            guard colon.first == ":" else { continue }
            return String(colon.dropFirst())
        }
        return nil
    }

    static func matches(_ key: String, in line: String) -> Bool {
        rawValue(for: key, in: line) != nil
    }
}

struct CloudflaredConfigParser: Sendable {
    func parse(contents: String, sourceURL: URL? = nil) throws -> CloudflaredConfigDocument {
        let normalizedContents = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalizedContents.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        guard let ingressIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return leadingWhitespaceCount(line) == 0 &&
                (trimmed == "ingress:" || trimmed.hasPrefix("ingress: #"))
        }) else {
            throw ConfigParsingError.missingIngress
        }

        let ingressIndent = leadingWhitespaceCount(lines[ingressIndex])
        var endIndex = lines.endIndex
        if ingressIndex + 1 < lines.endIndex {
            for index in (ingressIndex + 1)..<lines.endIndex {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty,
                   !trimmed.hasPrefix("#"),
                   leadingWhitespaceCount(lines[index]) <= ingressIndent {
                    endIndex = index
                    break
                }
            }
        }

        let prefix = Array(lines[..<ingressIndex])
        let body = Array(lines[(ingressIndex + 1)..<endIndex])
        let suffix = endIndex < lines.endIndex ? Array(lines[endIndex...]) : []
        let parsedBody = try parseIngressBody(body, parentIndent: ingressIndent)

        return CloudflaredConfigDocument(
            sourceURL: sourceURL,
            tunnel: scalarValue(for: "tunnel", in: prefix + suffix),
            credentialsFile: scalarValue(for: "credentials-file", in: prefix + suffix),
            ingress: parsedBody.rules,
            prefixLines: prefix,
            suffixLines: suffix,
            ingressLeadingLines: parsedBody.leadingLines,
            ingressHeaderLine: lines[ingressIndex],
            ingressRuleIndent: parsedBody.ruleIndent
        )
    }

    private func parseIngressBody(
        _ lines: [String],
        parentIndent: Int
    ) throws -> (rules: [IngressRule], leadingLines: [String], ruleIndent: Int) {
        var rules: [IngressRule] = []
        var leadingLines: [String] = []
        var current: ParsedRule?
        let ruleIndent = lines.compactMap { line -> Int? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = leadingWhitespaceCount(line)
            guard indent > parentIndent, trimmed == "-" || trimmed.hasPrefix("- ") else { return nil }
            return indent
        }.min()

        func finishCurrent(_ current: inout ParsedRule?, into rules: inout [IngressRule]) throws {
            guard let value = current else { return }
            guard let service = value.service, !service.isEmpty else {
                throw ConfigParsingError.malformedIngress("每条规则都需要设置 service。")
            }
            rules.append(IngressRule(
                hostname: value.hostname,
                path: value.path,
                service: service,
                preservedLines: value.preservedLines,
                hostnameComment: value.hostnameComment,
                pathComment: value.pathComment,
                serviceComment: value.serviceComment
            ))
            current = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = leadingWhitespaceCount(line)
            let isRuleStart = indent == ruleIndent && (trimmed == "-" || trimmed.hasPrefix("- "))

            if isRuleStart {
                try finishCurrent(&current, into: &rules)
                current = ParsedRule(ruleIndent: indent)
                let remainder = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !remainder.isEmpty {
                    guard remainder.hasPrefix("#") || isPlainMappingField(remainder) else {
                        throw ConfigParsingError.malformedIngress(
                            "规则首行只支持普通 key: value；暂不支持 YAML 锚点、别名、标签或流式写法。"
                        )
                    }
                    // A list item's first field shares the `-` line. Unknown fields must
                    // be preserved as fields of this map, not as a second list item when
                    // the rule is serialized after the editable fields.
                    let preservedFieldLine = String(repeating: " ", count: indent + 2) + remainder
                    applyKnownField(remainder, originalLine: preservedFieldLine, to: &current!)
                }
                continue
            }

            guard var value = current else {
                leadingLines.append(line)
                continue
            }

            if indent == value.ruleIndent + 2 {
                applyKnownField(trimmed, originalLine: line, to: &value)
            } else {
                value.preservedLines.append(line)
            }
            current = value
        }
        try finishCurrent(&current, into: &rules)
        return (rules, leadingLines, ruleIndent ?? parentIndent + 2)
    }

    private func isPlainMappingField(_ field: String) -> Bool {
        guard let colonIndex = field.firstIndex(of: ":") else { return false }
        let key = field[..<colonIndex].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty,
              key == "<<" || key.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (65...90).contains(scalar.value)
                      || (97...122).contains(scalar.value)
                      || scalar.value == 45
                      || scalar.value == 95
              }) else {
            return false
        }

        let valueStart = field.index(after: colonIndex)
        return valueStart == field.endIndex || field[valueStart].isWhitespace
    }

    private struct ParsedRule {
        let ruleIndent: Int
        var hostname: String?
        var path: String?
        var service: String?
        var preservedLines: [String] = []
        var hostnameComment: String?
        var pathComment: String?
        var serviceComment: String?
    }

    private func applyKnownField(
        _ field: String,
        originalLine: String,
        to rule: inout ParsedRule
    ) {
        if let value = parsedField("hostname", from: field) {
            rule.hostname = value.value
            rule.hostnameComment = value.trailingComment
        } else if let value = parsedField("path", from: field) {
            rule.path = value.value
            rule.pathComment = value.trailingComment
        } else if let value = parsedField("service", from: field) {
            rule.service = value.value
            rule.serviceComment = value.trailingComment
        } else {
            rule.preservedLines.append(originalLine)
        }
    }

    private func scalarValue(for key: String, in lines: [String]) -> String? {
        lines.lazy.compactMap { line -> String? in
            guard let rawValue = YAMLTopLevelScalarLine.rawValue(for: key, in: line) else {
                return nil
            }
            return decodeScalar(splitTrailingComment(rawValue).value)
        }.first
    }

    private struct ParsedField {
        let value: String
        let trailingComment: String?
    }

    private func parsedField(_ key: String, from field: String) -> ParsedField? {
        guard field.hasPrefix("\(key):") else { return nil }
        let raw = String(field.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        let parts = splitTrailingComment(raw)
        return ParsedField(value: decodeScalar(parts.value), trailingComment: parts.comment)
    }

    private func decodeScalar(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            let inner = String(value.dropFirst().dropLast())
            return decodeDoubleQuotedScalar(inner)
        }
        return value
    }

    private func decodeDoubleQuotedScalar(_ value: String) -> String {
        var result = ""
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]
            guard character == "\\" else {
                result.append(character)
                index = value.index(after: index)
                continue
            }

            let escapeIndex = value.index(after: index)
            guard escapeIndex < value.endIndex else {
                result.append("\\")
                break
            }

            let escape = value[escapeIndex]
            switch escape {
            case "0": result.append("\0")
            case "a": result.append("\u{7}")
            case "b": result.append("\u{8}")
            case "t", "\t": result.append("\t")
            case "n": result.append("\n")
            case "v": result.append("\u{B}")
            case "f": result.append("\u{C}")
            case "r": result.append("\r")
            case "e": result.append("\u{1B}")
            case " ": result.append(" ")
            case "\"": result.append("\"")
            case "/": result.append("/")
            case "\\": result.append("\\")
            case "N": result.append("\u{85}")
            case "_": result.append("\u{A0}")
            case "L": result.append("\u{2028}")
            case "P": result.append("\u{2029}")
            case "x", "u", "U":
                let digitCount = escape == "x" ? 2 : (escape == "u" ? 4 : 8)
                let digitsStart = value.index(after: escapeIndex)
                guard let digitsEnd = value.index(
                    digitsStart,
                    offsetBy: digitCount,
                    limitedBy: value.endIndex
                ) else {
                    result.append("\\")
                    result.append(escape)
                    index = digitsStart
                    continue
                }
                let digits = String(value[digitsStart..<digitsEnd])
                if let scalarValue = UInt32(digits, radix: 16),
                   let scalar = UnicodeScalar(scalarValue) {
                    result.unicodeScalars.append(scalar)
                    index = digitsEnd
                    continue
                }
                result.append("\\")
                result.append(escape)
                index = digitsStart
                continue
            default:
                // Keep invalid or unsupported YAML escapes losslessly. The official
                // cloudflared validation step will still reject an invalid scalar.
                result.append("\\")
                result.append(escape)
            }
            index = value.index(after: escapeIndex)
        }

        return result
    }

    private func splitTrailingComment(_ raw: String) -> (value: String, comment: String?) {
        var isInsideSingleQuote = false
        var isInsideDoubleQuote = false
        var isEscaped = false
        var previousWasWhitespace = true

        for index in raw.indices {
            let character = raw[index]
            if isInsideDoubleQuote, character == "\\", !isEscaped {
                isEscaped = true
                previousWasWhitespace = false
                continue
            }
            if character == "'", !isInsideDoubleQuote {
                isInsideSingleQuote.toggle()
            } else if character == "\"", !isInsideSingleQuote, !isEscaped {
                isInsideDoubleQuote.toggle()
            } else if character == "#", !isInsideSingleQuote, !isInsideDoubleQuote, previousWasWhitespace {
                let value = String(raw[..<index]).trimmingCharacters(in: .whitespaces)
                return (value, String(raw[index...]))
            }
            previousWasWhitespace = character.isWhitespace
            isEscaped = false
        }
        return (raw, nil)
    }

    private func leadingWhitespaceCount(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }
}

struct CloudflaredConfigSerializer: Sendable {
    func serialize(_ document: CloudflaredConfigDocument) -> String {
        var prefixLines = document.prefixLines
        var suffixLines = document.suffixLines
        let normalizedTunnel = normalized(document.tunnel)
        let tunnelChanged = normalizedTunnel != normalized(document.originalTunnel)
        let tunnelExists = containsTopLevelScalar("tunnel", in: prefixLines)
            || containsTopLevelScalar("tunnel", in: suffixLines)

        if tunnelChanged {
            let prefixResult = replacingTopLevelScalar(
                "tunnel",
                value: normalizedTunnel,
                in: prefixLines
            )
            prefixLines = prefixResult.lines
            var tunnelWasFound = prefixResult.found
            if !tunnelWasFound {
                let suffixResult = replacingTopLevelScalar(
                    "tunnel",
                    value: normalizedTunnel,
                    in: suffixLines
                )
                suffixLines = suffixResult.lines
                tunnelWasFound = suffixResult.found
            }
            if !tunnelWasFound, let normalizedTunnel {
                insertTopLevelScalar(
                    "tunnel",
                    value: normalizedTunnel,
                    into: &prefixLines
                )
            }
        } else if !tunnelExists, let normalizedTunnel {
            insertTopLevelScalar(
                "tunnel",
                value: normalizedTunnel,
                into: &prefixLines
            )
        }

        var lines = prefixLines
        lines.append(document.ingressHeaderLine)
        lines.append(contentsOf: document.ingressLeadingLines)
        let ruleIndent = String(repeating: " ", count: document.ingressRuleIndent)
        let fieldIndent = ruleIndent + "  "

        for rule in document.ingress {
            var fields: [(key: String, value: String, comment: String?)] = []
            if let hostname = normalized(rule.hostname) {
                fields.append(("hostname", hostname, rule.hostnameComment))
            }
            if let path = normalized(rule.path) {
                fields.append(("path", path, rule.pathComment))
            }
            fields.append((
                "service",
                rule.service.trimmingCharacters(in: .whitespacesAndNewlines),
                rule.serviceComment
            ))

            if let first = fields.first {
                lines.append("\(ruleIndent)- \(first.key): \(quoted(first.value))\(formatted(first.comment))")
                for field in fields.dropFirst() {
                    lines.append("\(fieldIndent)\(field.key): \(quoted(field.value))\(formatted(field.comment))")
                }
            }
            lines.append(contentsOf: rule.preservedLines)
        }
        lines.append(contentsOf: suffixLines)
        return lines.joined(separator: "\n") + "\n"
    }

    private func containsTopLevelScalar(_ key: String, in lines: [String]) -> Bool {
        lines.contains { YAMLTopLevelScalarLine.matches(key, in: $0) }
    }

    private func replacingTopLevelScalar(
        _ key: String,
        value: String?,
        in lines: [String]
    ) -> (lines: [String], found: Bool) {
        guard let index = lines.firstIndex(where: {
            YAMLTopLevelScalarLine.matches(key, in: $0)
        }) else {
            return (lines, false)
        }

        var result = lines
        guard let value else {
            result.remove(at: index)
            return (result, true)
        }
        let comment = trailingComment(in: result[index])
        result[index] = "\(key): \(quoted(value))\(formatted(comment))"
        return (result, true)
    }

    private func insertTopLevelScalar(
        _ key: String,
        value: String,
        into lines: inout [String]
    ) {
        let insertionIndex = lines.lastIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }).map { lines.index(after: $0) } ?? lines.startIndex
        lines.insert("\(key): \(quoted(value))", at: insertionIndex)
    }

    private func trailingComment(in line: String) -> String? {
        var singleQuoted = false
        var doubleQuoted = false
        var escaped = false
        var previousWasWhitespace = true

        for index in line.indices {
            let character = line[index]
            if doubleQuoted, character == "\\", !escaped {
                escaped = true
                previousWasWhitespace = false
                continue
            }
            if character == "'", !doubleQuoted {
                singleQuoted.toggle()
            } else if character == "\"", !singleQuoted, !escaped {
                doubleQuoted.toggle()
            } else if character == "#", !singleQuoted, !doubleQuoted, previousWasWhitespace {
                return String(line[index...])
            }
            previousWasWhitespace = character.isWhitespace
            escaped = false
        }
        return nil
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func quoted(_ value: String) -> String {
        if value.unicodeScalars.contains(where: { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) ||
                scalar.value == 0x2028 || scalar.value == 0x2029
        }) {
            return doubleQuoted(value)
        }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func doubleQuoted(_ value: String) -> String {
        var encoded = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x00: encoded += "\\0"
            case 0x07: encoded += "\\a"
            case 0x08: encoded += "\\b"
            case 0x09: encoded += "\\t"
            case 0x0A: encoded += "\\n"
            case 0x0B: encoded += "\\v"
            case 0x0C: encoded += "\\f"
            case 0x0D: encoded += "\\r"
            case 0x1B: encoded += "\\e"
            case 0x22: encoded += "\\\""
            case 0x5C: encoded += "\\\\"
            case 0x85: encoded += "\\N"
            case 0xA0: encoded += "\\_"
            case 0x2028: encoded += "\\L"
            case 0x2029: encoded += "\\P"
            case 0x01...0x1F, 0x7F...0x9F:
                encoded += String(format: "\\x%02X", scalar.value)
            default:
                encoded.unicodeScalars.append(scalar)
            }
        }
        return "\"\(encoded)\""
    }

    private func formatted(_ comment: String?) -> String {
        guard let comment, !comment.isEmpty else { return "" }
        return " \(comment)"
    }
}
