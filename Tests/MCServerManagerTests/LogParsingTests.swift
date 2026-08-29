import XCTest
@testable import MCServerManager

final class LogParsingTests: XCTestCase {

    // MARK: - LogEntry prefix stripping

    func testVanillaLineIsParsed() {
        let e = LogEntry(raw: #"[12:34:56] [Server thread/INFO]: Done (3.456s)! For help, type "help""#)
        XCTAssertEqual(e.time, "12:34:56")
        XCTAssertEqual(e.level, .info)
        XCTAssertEqual(e.message, #"Done (3.456s)! For help, type "help""#)
    }

    func testForgeLineWithLoggerBracketIsParsed() {
        let e = LogEntry(raw: "[12:34:56] [Server thread/INFO] [minecraft/PlayerList]: Steve[/127.0.0.1:50000] logged in with entity id 42 at (0.5, 64.0, 0.5)")
        XCTAssertEqual(e.time, "12:34:56")
        XCTAssertEqual(e.level, .info)
        XCTAssertEqual(e.message, "Steve[/127.0.0.1:50000] logged in with entity id 42 at (0.5, 64.0, 0.5)")
    }

    func testNeoForgeWarnLineIsParsed() {
        let e = LogEntry(raw: "[09:00:01] [Server thread/WARN] [net.minecraft.server.MinecraftServer/]: Can't keep up! Is the server overloaded? Running 2100ms or 42 ticks behind")
        XCTAssertEqual(e.level, .warn)
        XCTAssertTrue(e.message.hasPrefix("Can't keep up!"))
    }

    // MARK: - Player join

    func testJoinVanilla() {
        XCTAssertEqual(
            LogParsing.playerEvent(from: "Steve[/127.0.0.1:50000] logged in with entity id 42 at (0.5, 64.0, 0.5)"),
            .joined("Steve")
        )
    }

    func testJoinBedrockPrefixedName() {
        XCTAssertEqual(
            LogParsing.playerEvent(from: ".Alex_99[/10.0.0.4:19132] logged in with entity id 7 at (1, 2, 3)"),
            .joined(".Alex_99")
        )
    }

    func testJoinFallsBackWhenPrefixNotStripped() {
        // Defensive: an unparsed raw line still yields the right name.
        let raw = "[12:00:00] [Server thread/INFO] [minecraft/PlayerList]: Notch[/127.0.0.1:1] logged in with entity id 1 at (0, 0, 0)"
        XCTAssertEqual(LogParsing.playerEvent(from: raw), .joined("Notch"))
    }

    // MARK: - Player leave

    func testLeaveLostConnection() {
        XCTAssertEqual(
            LogParsing.playerEvent(from: "Steve lost connection: Disconnected"),
            .left("Steve")
        )
    }

    func testLeaveLeftTheGame() {
        XCTAssertEqual(
            LogParsing.playerEvent(from: "Steve left the game"),
            .left("Steve")
        )
    }

    func testLeaveFallsBackWhenPrefixNotStripped() {
        let raw = "[12:00:00] [Server thread/INFO] [minecraft/MinecraftServer]: Steve left the game"
        XCTAssertEqual(LogParsing.playerEvent(from: raw), .left("Steve"))
    }

    // MARK: - Negatives

    func testChatMentioningLeftTheGameIsIgnored() {
        XCTAssertNil(LogParsing.playerEvent(from: "<Griefer> haha Steve left the game"))
    }

    func testUnrelatedLineIsIgnored() {
        XCTAssertNil(LogParsing.playerEvent(from: "Preparing spawn area: 82%"))
        XCTAssertNil(LogParsing.playerEvent(from: #"Done (3.456s)! For help, type "help""#))
    }

    func testAuthenticatorUuidLineIsNotAJoin() {
        // This precedes the real "logged in with entity id" line and must not match.
        XCTAssertNil(LogParsing.playerEvent(from: "UUID of player Steve is 11111111-2222-3333-4444-555555555555"))
    }
}
