import Foundation

/// Pure, side-effect-free parsing of Minecraft server console output.
///
/// Kept separate from `ServerInstance` so it can be unit tested without spawning a
/// real server process. All functions take a single already-trimmed log message
/// (the text after `LogEntry` has stripped any `[time] [thread/LEVEL]` prefix) and
/// must also cope with a raw line whose prefix could not be stripped (older or
/// unusual mod-loader formats), hence the defensive `]: ` fallback.
enum LogParsing {

    /// A player session change reported on one log line.
    enum PlayerEvent: Equatable {
        case joined(String)
        case left(String)
    }

    /// Extracts a player join/leave from a single log message, or `nil` when the
    /// line is not a session event.
    ///
    /// Recognised forms (vanilla, Paper, Spigot, Purpur, Forge, NeoForge all emit
    /// one of these):
    ///   - `<name>[/<ip>:<port>] logged in with entity id <n> at (...)`  → joined
    ///   - `<name> lost connection: <reason>`                            → left
    ///   - `<name> left the game`                                        → left
    static func playerEvent(from message: String) -> PlayerEvent? {
        if message.contains("logged in with entity id"),
           let bracket = message.range(of: "[/"),
           let name = playerName(in: message[message.startIndex..<bracket.lowerBound]) {
            return .joined(name)
        }
        for marker in [" lost connection:", " left the game"] {
            if let range = message.range(of: marker),
               let name = playerName(in: message[message.startIndex..<range.lowerBound]) {
                return .left(name)
            }
        }
        return nil
    }

    /// Normalises the text that precedes an event marker into a bare player name,
    /// or `nil` if it does not look like one.
    private static func playerName(in candidate: Substring) -> String? {
        var name = candidate.trimmingCharacters(in: .whitespaces)
        // Drop a log prefix that survived (unstripped Forge/older lines):
        //   "[12:34:56] [Server thread/INFO] [minecraft/PlayerList]: Steve" → "Steve"
        if let colon = name.range(of: "]: ", options: .backwards) {
            name = String(name[colon.upperBound...])
        }
        guard !name.isEmpty, name.count <= 32, !name.contains(where: \.isWhitespace) else { return nil }
        // Java names are [A-Za-z0-9_]; Geyser/Floodgate Bedrock names may carry a
        // single prefix punctuation character. Reject anything with chat framing
        // ("<", ">", "[", ":") or other leftover markup.
        let allowedPunctuation: Set<Character> = ["_", ".", "-"]
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || allowedPunctuation.contains($0) }) else { return nil }
        return name
    }
}
