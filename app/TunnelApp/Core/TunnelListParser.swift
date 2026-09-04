import Foundation

struct TunnelListParser: Sendable {
    func parse(_ data: Data) throws -> [CloudflaredTunnel] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CloudflaredError.invalidTunnelList(error.localizedDescription)
        }

        guard let rows = object as? [[String: Any]] else {
            throw CloudflaredError.invalidTunnelList("预期返回 JSON 数组。")
        }

        return try rows.map { row in
            guard let id = Self.stringValue(row["id"]), !id.isEmpty,
                  let name = Self.stringValue(row["name"]), !name.isEmpty else {
                throw CloudflaredError.invalidTunnelList("某个隧道缺少 ID 或名称。")
            }

            let connections = row["connections"] as? [Any] ?? []
            return CloudflaredTunnel(
                id: id,
                name: name,
                createdAt: Self.dateValue(row["created_at"]),
                deletedAt: Self.deletedDateValue(row["deleted_at"]),
                connectionCount: connections.count
            )
        }
    }

    func parse(_ string: String) throws -> [CloudflaredTunnel] {
        guard let data = string.data(using: .utf8) else {
            throw CloudflaredError.invalidTunnelList("响应不是有效的 UTF-8 文本。")
        }
        return try parse(data)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let uuid = value as? UUID { return uuid.uuidString }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }

        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return regular.date(from: text)
    }

    private static func deletedDateValue(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !isGoZeroTime(normalized) else { return nil }
        return dateValue(normalized)
    }

    private static func isGoZeroTime(_ value: String) -> Bool {
        let prefix = "0001-01-01T00:00:00"
        guard value.hasPrefix(prefix), value.hasSuffix("Z") else { return false }

        let suffix = value.dropFirst(prefix.count).dropLast()
        if suffix.isEmpty { return true }
        guard suffix.first == ".", suffix.count > 1 else { return false }
        return suffix.dropFirst().allSatisfy { $0 == "0" }
    }
}
