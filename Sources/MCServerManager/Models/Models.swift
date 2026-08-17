import Foundation
import SwiftUI
import CryptoKit

// MARK: - ServerStatus

enum ServerStatus: Equatable {
    case stopped, starting, running, stopping, orphaned

    var label: String {
        switch self {
        case .stopped:  return L10n.text("停止中", "Stopped")
        case .starting: return L10n.text("起動中...", "Starting...")
        case .running:  return L10n.text("稼働中", "Running")
        case .stopping: return L10n.text("停止処理中...", "Stopping...")
        case .orphaned: return L10n.text("外部プロセス検出", "Detached process")
        }
    }

    var color: Color {
        switch self {
        case .stopped:  return .secondary
        case .starting: return .yellow
        case .running:  return .green
        case .stopping: return .orange
        case .orphaned: return .red
        }
    }

    var dotColor: Color { color }
    var isActive: Bool { self != .stopped }
    var canStart: Bool  { self == .stopped }
    var canStop: Bool   { self == .running || self == .starting }

    var apiString: String {
        switch self {
        case .stopped:  return "stopped"
        case .starting: return "starting"
        case .running:  return "running"
        case .stopping: return "stopping"
        case .orphaned: return "orphaned"
        }
    }
}

// MARK: - ServerProfile

struct ServerProfile: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var jvmArgs: String
    var autoStartServer: Bool

    init(id: UUID = UUID(), name: String, path: String, jvmArgs: String = "", autoStartServer: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.jvmArgs = jvmArgs
        self.autoStartServer = autoStartServer
    }

    var isValid: Bool {
        FileManager.default.fileExists(atPath: path + "/server.properties")
    }

    var hasStartScript: Bool {
        FileManager.default.fileExists(atPath: path + "/start.sh")
    }

    var jarName: String? {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return items.first { f in
            f.hasSuffix(".jar") &&
            (f.hasPrefix("paper") || f.hasPrefix("spigot") || f.hasPrefix("purpur") || f == "server.jar")
        }
    }

    func readProperty(_ key: String, default def: String) -> String {
        let propsPath = path + "/server.properties"
        guard let content = try? String(contentsOfFile: propsPath, encoding: .utf8) else { return def }
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key + "=") {
                return String(trimmed.dropFirst(key.count + 1))
            }
        }
        return def
    }

    var worldName: String  { readProperty("level-name", default: "world") }
    var serverPort: String { readProperty("server-port", default: "25565") }
    var motd: String       { readProperty("motd", default: name) }
    var maxPlayers: String { readProperty("max-players", default: "40") }

    var whitelistEnabled: Bool { readProperty("white-list", default: "false").lowercased() == "true" }

    /// Supports both the traditional 1.20.x/1.21.x scheme and Mojang's year-based 26.x scheme.
    var minecraftVersion: MinecraftVersion {
        let candidates = [jarName ?? "", motd, readVersionHistory()]
        for text in candidates {
            if let version = MinecraftVersion.detect(in: text) { return version }
        }
        return .unknown
    }

    private func readVersionHistory() -> String {
        (try? String(contentsOfFile: path + "/version_history.json", encoding: .utf8)) ?? ""
    }

    @discardableResult
    func writeProperties(_ changes: [String: String]) -> Bool {
        let url = URL(fileURLWithPath: path).appendingPathComponent("server.properties")
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var remaining = changes
        var lines = original.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equal = trimmed.firstIndex(of: "=") else { return line }
            let key = String(trimmed[..<equal])
            guard let value = remaining.removeValue(forKey: key) else { return line }
            return "\(key)=\(value)"
        }
        for key in remaining.keys.sorted() { lines.append("\(key)=\(remaining[key]!)") }
        do { try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }
}

// MARK: - Minecraft version compatibility

struct MinecraftVersion: Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let isYearBased: Bool

    static let unknown = MinecraftVersion(major: 0, minor: 0, patch: 0, isYearBased: false)

    var description: String {
        guard self != .unknown else { return "Unknown" }
        return isYearBased ? "\(major).\(minor).\(patch)" : "1.\(minor).\(patch)"
    }

    var requiredJavaMajor: Int {
        if isYearBased { return major >= 26 ? 25 : 21 }
        if minor == 20 && patch <= 4 { return 17 }
        return 21
    }

    static func detect(in text: String) -> MinecraftVersion? {
        let patterns = [#"(?<![0-9])1\.(20|21)(?:\.(\d+))?"#, #"(?<![0-9])(2[6-9])\.(\d+)(?:\.(\d+))?"#]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            func number(_ group: Int) -> Int {
                let range = match.range(at: group)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return 0 }
                return Int(text[swiftRange]) ?? 0
            }
            if index == 0 { return MinecraftVersion(major: 1, minor: number(1), patch: number(2), isYearBased: false) }
            return MinecraftVersion(major: number(1), minor: number(2), patch: number(3), isYearBased: true)
        }
        return nil
    }
}

struct ServerMetrics {
    var memoryMB: Double = 0
    var cpuPercent: Double = 0
    var latencyMS: Double?
    var tps: Double?
    var mspt: Double?
    var lagMS: Double = 0
    var memoryLeakWarning = false
    var updatedAt: Date?
}

enum MetricsAnalysis {
    /// A conservative leak hint: at least two minutes of samples, sustained positive trend,
    /// meaningful total growth, and a reasonably linear pattern.
    static func hasSustainedMemoryGrowth(_ samples: [(Date, Double)]) -> Bool {
        guard samples.count >= 24, let first = samples.first, let last = samples.last else { return false }
        let durationMinutes = last.0.timeIntervalSince(first.0) / 60
        guard durationMinutes >= 2 else { return false }
        let xs = samples.map { $0.0.timeIntervalSince(first.0) / 60 }
        let ys = samples.map(\.1)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let denominator = xs.reduce(0) { $0 + pow($1 - meanX, 2) }
        guard denominator > 0 else { return false }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) } / denominator
        let predicted = xs.map { meanY + slope * ($0 - meanX) }
        let residual = zip(ys, predicted).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
        let total = ys.reduce(0) { $0 + pow($1 - meanY, 2) }
        let rSquared = total > 0 ? 1 - residual / total : 0
        let growth = last.1 - first.1
        return slope >= 50 && growth >= max(256, first.1 * 0.15) && rSquared >= 0.60
    }
}

// MARK: - LogEntry

struct LogEntry: Identifiable {
    let id = UUID()
    let raw: String
    let time: String
    let level: LogLevel
    let message: String

    enum LogLevel {
        case info, warn, error, debug, other

        var color: Color {
            switch self {
            case .info:  return .primary
            case .warn:  return Color(red: 1.0, green: 0.85, blue: 0.0)
            case .error: return Color(red: 1.0, green: 0.35, blue: 0.35)
            case .debug: return .secondary
            case .other: return .secondary
            }
        }

        var badge: String {
            switch self {
            case .info:  return "INFO"
            case .warn:  return "WARN"
            case .error: return "ERRR"
            case .debug: return "DBUG"
            case .other: return "    "
            }
        }

        var badgeColor: Color {
            switch self {
            case .warn:  return Color(red: 1.0, green: 0.85, blue: 0.0).opacity(0.25)
            case .error: return Color(red: 1.0, green: 0.35, blue: 0.35).opacity(0.25)
            default:     return .clear
            }
        }
    }

    init(raw: String) {
        self.raw = raw

        let patterns = [
            #"^\[(\d{2}:\d{2}:\d{2})\] \[[^\]]+/(INFO|WARN|ERROR|DEBUG)\]: (.*)$"#,
            #"^\[(\d{2}:\d{2}:\d{2}) (INFO|WARN|ERROR|DEBUG)\]: (.*)$"#,
        ]

        var parsedTime    = ""
        var parsedLevel   = LogLevel.other
        var parsedMessage = raw

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = raw as NSString
            guard let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }

            func grp(_ i: Int) -> String {
                guard let r = Range(m.range(at: i), in: raw) else { return "" }
                return String(raw[r])
            }

            parsedTime    = grp(1)
            parsedMessage = grp(3)
            switch grp(2) {
            case "INFO":  parsedLevel = .info
            case "WARN":  parsedLevel = .warn
            case "ERROR": parsedLevel = .error
            case "DEBUG": parsedLevel = .debug
            default:      parsedLevel = .other
            }
            break
        }

        time    = parsedTime
        level   = parsedLevel
        message = parsedMessage
    }
}

// MARK: - User Management Models

struct WhitelistEntry: Codable, Identifiable, Equatable {
    let uuid: String
    let name: String
    var id: String { uuid }
}

struct OpsEntry: Codable, Identifiable, Equatable {
    let uuid: String
    let name: String
    let level: Int
    let bypassesPlayerLimit: Bool
    var id: String { uuid }
}

struct BanEntry: Codable, Identifiable, Equatable {
    let uuid: String?
    let name: String?
    let created: String?
    let source: String?
    let expires: String?
    let reason: String?
    var id: String { uuid ?? name ?? UUID().uuidString }

    var displayName: String { name ?? "(不明)" }
    var displayReason: String { reason ?? "理由なし" }
}

// MARK: - UserCache

struct UserCacheEntry: Codable {
    let uuid: String
    let name: String
    let expiresOn: String?
}

// MARK: - Pending Whitelist (Bedrock players waiting for server start)

struct PendingWhitelistEntry: Codable, Identifiable {
    var id: UUID = UUID()
    let name: String      // Display name (as entered)
    let command: String   // "whitelist add .gamertag"
    let addedAt: Date
}

// MARK: - Player Platform (for add UI)

enum PlayerPlatform: String, CaseIterable {
    case auto    = "自動"
    case java    = "Java"
    case bedrock = "統合版"

    var label: String {
        switch self {
        case .auto: return L10n.text("自動", "Auto")
        case .java: return "Java"
        case .bedrock: return L10n.text("統合版", "Bedrock")
        }
    }
}

// MARK: - User file helpers

enum UserFiles {
    static func isValidPlayerName(_ name: String) -> Bool {
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 32 else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || "_.- ".unicodeScalars.contains(scalar)
        }
    }

    static func load<T: Decodable>(_ filename: String, from serverPath: String) -> [T] {
        let url = URL(fileURLWithPath: serverPath).appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([T].self, from: data) else { return [] }
        return entries
    }

    static func save<T: Encodable>(_ entries: [T], filename: String, to serverPath: String) {
        let url = URL(fileURLWithPath: serverPath).appendingPathComponent(filename)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(entries) else { return }
        try? data.write(to: url)
    }

    static func lookupCache(name: String, in serverPath: String) -> UserCacheEntry? {
        let entries: [UserCacheEntry] = load("usercache.json", from: serverPath)
        return entries.first { $0.name.lowercased() == name.lowercased() }
    }

    static func floodgatePrefix(in serverPath: String) -> String {
        let configPath = serverPath + "/plugins/floodgate/config.yml"
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return "." }
        for line in content.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("username-prefix:") {
                let raw = String(t.dropFirst("username-prefix:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return raw.isEmpty ? "." : raw
            }
        }
        return "."
    }

    // Strip Floodgate prefix from a Bedrock name (needed for fwhitelist add)
    static func stripFloodgatePrefix(from name: String, in serverPath: String) -> String {
        let prefix = floodgatePrefix(in: serverPath)
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    static func offlinePlayerUUID(name: String) -> String {
        var bytes = Array(Insecure.MD5.hash(data: Data("OfflinePlayer:\(name)".utf8)))
        bytes[6] = (bytes[6] & 0x0f) | 0x30  // version 3
        bytes[8] = (bytes[8] & 0x3f) | 0x80  // variant 1
        return String(format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],
            bytes[6],  bytes[7],
            bytes[8],  bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
    }

    // UUID resolution: cache → offline Java → nil (Bedrock no-cache)
    static func resolvePlayer(name: String, in serverPath: String) -> (uuid: String, note: String)? {
        if let hit = lookupCache(name: name, in: serverPath) {
            let isBedrock = hit.uuid.hasPrefix("00000000-0000-0000-0009-")
            return (hit.uuid, isBedrock ? "統合版 (キャッシュ)" : "キャッシュ")
        }
        let prefix = floodgatePrefix(in: serverPath)
        if name.hasPrefix(prefix) {
            return nil  // Bedrock, no cache
        }
        return (offlinePlayerUUID(name: name), "オフライン UUID")
    }
}
