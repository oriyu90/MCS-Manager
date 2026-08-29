# Changelog

## 1.1.0 — 2026-08-30

### Fixed

- Online-player detection on Forge and NeoForge servers. `LogEntry` now strips the
  extra `[logger/name]` segment those loaders insert before the message, so player
  join and leave lines are parsed correctly instead of producing a garbled entry
  that never cleared. Join/leave parsing moved into a pure, unit-tested
  `LogParsing` helper.

### Changed

- The built-in Web dashboard "Users" tab now manages operators and bans in
  addition to the whitelist, matching the native app and the REST API. The tab
  was previously whitelist-only.
- Removed an unused second copy of the Web UI that was embedded in `HTTPServer`
  and never served.

### Added

- `MCServerManagerTests` target with coverage for server-log parsing.

Copyright © 2026 Yuki_Orita. Released under the MIT License.

## 1.0.0 — 2026-08-17

Initial public release of MCS Manager.

### Highlights

- Native macOS menu-bar management for multiple Minecraft Java servers
- Paper, Spigot, Purpur, vanilla JAR, and custom `start.sh` support
- Minecraft 1.20.x, 1.21.x, and 26.x Java compatibility detection
- Built-in Japanese/English Web dashboard and REST API
- Server status, player, memory, CPU, latency, TPS, MSPT, and lag monitoring
- Whitelist, operator, ban, console, and server-settings management
- Safe shutdown, PID recovery, bounded monitoring, and hardened HTTP handling
- Japanese-first, high-contrast native and Web interfaces

Copyright © 2026 Yuki_Orita. Released under the MIT License.
