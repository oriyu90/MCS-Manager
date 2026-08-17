// Simple HTTP/1.1 REST API server using Network.framework (no external dependencies)
// Used by the remote web management UI.

import Foundation
import Network

// All mutable transport state is confined to `queue`; manager access hops to MainActor.
final class HTTPServer: @unchecked Sendable {

    weak var manager: ServerManager?
    var password: String = ""

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mc.http.server", qos: .utility)
    private let port: UInt16
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private let maximumConnections = 64
    private let maximumHeaderBytes = 32 * 1024
    private let maximumBodyBytes = 1024 * 1024
    private let requestTimeout: TimeInterval = 15

    init(port: UInt16 = 25580) {
        self.port = port
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

        listener?.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }

        listener?.stateUpdateHandler = { state in
            if case .failed(let e) = state {
                print("[WebAPI] listener error: \(e)")
            }
        }

        listener?.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.activeConnections.values.forEach { $0.cancel() }
            self.activeConnections.removeAll()
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        guard activeConnections.count < maximumConnections else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        activeConnections[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state { self.cleanup(connection) }
            if case .cancelled = state { self.cleanup(connection) }
        }
        connection.start(queue: queue)
        receiveRequest(from: connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak self, weak connection] in
            guard let self, let connection,
                  self.activeConnections[ObjectIdentifier(connection)] != nil else { return }
            self.cleanup(connection)
            connection.cancel()
        }
    }

    private func receiveRequest(from conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, error == nil else { self?.cleanup(conn); conn.cancel(); return }

            var buf = buffer
            if let d = data { buf.append(d) }
            if buf.count > self.maximumHeaderBytes + self.maximumBodyBytes {
                self.finish(conn, response: self.resp(413, #"{"error":"request too large"}"#))
                return
            }

            // Wait for end of HTTP headers (\r\n\r\n)
            guard let delimData = "\r\n\r\n".data(using: .utf8),
                  let range = buf.range(of: delimData) else {
                if buf.count > self.maximumHeaderBytes {
                    self.finish(conn, response: self.resp(413, #"{"error":"headers too large"}"#))
                } else if !done {
                    self.receiveRequest(from: conn, buffer: buf)
                } else {
                    self.finish(conn, response: self.resp(400, #"{"error":"incomplete request"}"#))
                }
                return
            }

            let headersStr = String(data: buf[..<range.lowerBound], encoding: .utf8) ?? ""
            var body = Data(buf[range.upperBound...])

            let headerLines = headersStr.components(separatedBy: "\r\n")
            if headerLines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }) {
                self.finish(conn, response: self.resp(400, #"{"error":"transfer encoding is not supported"}"#))
                return
            }
            let lengthHeaders = headerLines.filter { $0.lowercased().hasPrefix("content-length:") }
            guard lengthHeaders.count <= 1 else {
                self.finish(conn, response: self.resp(400, #"{"error":"ambiguous content length"}"#))
                return
            }
            let contentLength: Int
            if let lengthHeader = lengthHeaders.first {
                let value = lengthHeader.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                guard let parsed = Int(value) else {
                    self.finish(conn, response: self.resp(400, #"{"error":"invalid content length"}"#))
                    return
                }
                contentLength = parsed
            } else {
                contentLength = 0
            }

            guard contentLength >= 0, contentLength <= self.maximumBodyBytes else {
                self.finish(conn, response: self.resp(413, #"{"error":"body too large"}"#))
                return
            }

            if body.count < contentLength && !done {
                self.receiveRequest(from: conn, buffer: buf)
                return
            }
            body = Data(body.prefix(contentLength))

            Task { [weak self] in
                guard let self else { return }
                let response = await self.dispatch(headers: headersStr,
                                                   body: String(data: body, encoding: .utf8) ?? "")
                self.queue.async { self.finish(conn, response: response) }
            }
        }
    }

    private func finish(_ connection: NWConnection, response: Data) {
        connection.send(content: response, completion: .contentProcessed { [weak self, weak connection] _ in
            guard let self, let connection else { return }
            self.cleanup(connection)
            connection.cancel()
        })
    }

    private func cleanup(_ connection: NWConnection) {
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
    }

    // MARK: - Dispatch

    private func dispatch(headers: String, body: String) async -> Data {
        let headerLines = headers.components(separatedBy: "\r\n")
        guard let rl = headerLines.first, !rl.isEmpty else { return resp(400, #"{"error":"bad request"}"#) }

        let parts = rl.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0",
              parts[1].utf8.count <= 2048 else { return resp(400, #"{"error":"bad request"}"#) }

        let method = parts[0].uppercased()
        guard ["GET", "POST", "DELETE", "OPTIONS"].contains(method) else {
            return resp(400, #"{"error":"unsupported method"}"#)
        }
        let path   = parts[1].components(separatedBy: "?")[0]

        // CORS preflight
        if method == "OPTIONS" { return resp(200, "") }

        // The dashboard shell must be reachable so it can present its own login form.
        if method == "GET" && (path == "/" || path == "/index.html") {
            return await route(method: method, path: path, body: body)
        }

        // Auth
        if !password.isEmpty {
            let authLine = headerLines.first { $0.lowercased().hasPrefix("authorization:") } ?? ""
            // accept "Bearer <password>" or just the raw password
            let token = authLine.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
            let bearer = token.hasPrefix("Bearer ") ? String(token.dropFirst("Bearer ".count)) : token
            guard bearer == password else { return resp(401, #"{"error":"unauthorized"}"#) }
        }

        return await route(method: method, path: path, body: body)
    }

    // MARK: - Routing

    private func route(method: String, path: String, body: String) async -> Data {
        let s = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        // GET / — serve built-in web UI (works from iPad Safari directly over HTTP)
        if method == "GET" && (path == "/" || path == "/index.html") {
            return respHTML(WebDashboard.html)
        }

        // GET /api/status
        if method == "GET" && s == ["api", "status"] {
            return await MainActor.run { self.handleStatus() }
        }
        // GET /api/servers
        if method == "GET" && s == ["api", "servers"] {
            return await MainActor.run { self.handleServers() }
        }
        // Server control: /api/servers/{id}/{action}
        if s.count == 4 && s[0] == "api" && s[1] == "servers" {
            let id = s[2]; let action = s[3]
            switch (method, action) {
            case ("POST", "start"):   return await instanceAction(id) { $0.start() }
            case ("POST", "stop"):    return await instanceAction(id) { $0.stop() }
            case ("POST", "restart"): return await instanceAction(id) { $0.restart() }
            case ("POST", "kill"):    return await instanceAction(id) { $0.forceKill() }
            case ("POST", "command"): return await handleCommand(id: id, body: body)
            case ("GET",  "logs"):    return await MainActor.run { self.handleLogs(id: id) }
            case ("GET",  "players"): return await MainActor.run { self.handlePlayers(id: id) }
            case ("GET",  "metrics"): return await MainActor.run { self.handleMetrics(id: id) }
            case ("GET",  "settings"): return await MainActor.run { self.handleSettingsGet(id: id) }
            case ("POST", "settings"): return await handleSettingsUpdate(id: id, body: body)
            case ("GET",  "whitelist"): return await MainActor.run { self.handleWhitelistGet(id: id) }
            case ("POST", "whitelist"): return await handleWhitelistAdd(id: id, body: body)
            case ("POST", "whitelist-enabled"): return await handleWhitelistEnabled(id: id, body: body)
            case ("GET",  "ops"):     return await MainActor.run { self.handleOpsGet(id: id) }
            case ("POST", "ops"):     return await handleOpsAdd(id: id, body: body)
            case ("GET",  "bans"):    return await MainActor.run { self.handleBansGet(id: id) }
            default: break
            }
        }
        // DELETE /api/servers/{id} removes the profile only; server files are never deleted.
        if method == "DELETE" && s.count == 3 && s[0] == "api" && s[1] == "servers" {
            return await handleServerDelete(id: s[2])
        }
        // DELETE /api/servers/{id}/whitelist/{uuid}
        if method == "DELETE" && s.count == 5 && s[0] == "api" && s[1] == "servers" && s[3] == "whitelist" {
            return await handleWhitelistDelete(id: s[2], uuid: s[4])
        }
        // DELETE /api/servers/{id}/ops/{uuid}
        if method == "DELETE" && s.count == 5 && s[0] == "api" && s[1] == "servers" && s[3] == "ops" {
            return await handleOpsDelete(id: s[2], uuid: s[4])
        }
        // POST /api/servers/{id}/bans/{name}/pardon
        if method == "POST" && s.count == 6 && s[0] == "api" && s[1] == "servers" && s[3] == "bans" && s[5] == "pardon" {
            return await handlePardon(id: s[2], playerName: s[4])
        }

        return resp(404, #"{"error":"not found"}"#)
    }

    // MARK: - Handlers

    @MainActor
    private func handleStatus() -> Data {
        guard let manager else { return resp(503, #"{"error":"not ready"}"#) }
        let servers: [[String: Any]] = manager.instances.values.map { inst in [
            "id":          inst.id.uuidString,
            "name":        inst.profile.name,
            "status":      inst.status.apiString,
            "playerCount": inst.onlinePlayers.count,
            "maxPlayers":  Int(inst.profile.maxPlayers) ?? 20,
            "port":        Int(inst.profile.serverPort) ?? 25565,
            "uptime":      Int(inst.uptime),
            "jar":         inst.profile.jarName ?? "",
            "version":     inst.profile.minecraftVersion.description,
            "whitelistEnabled": inst.profile.whitelistEnabled,
            "memoryMB":    inst.metrics.memoryMB,
            "cpuPercent":  inst.metrics.cpuPercent,
            "latencyMS":   inst.metrics.latencyMS.map { $0 as Any } ?? NSNull(),
            "tps":         inst.metrics.tps.map { $0 as Any } ?? NSNull(),
            "mspt":        inst.metrics.mspt.map { $0 as Any } ?? NSNull(),
            "lagMS":       inst.metrics.lagMS,
            "memoryLeakWarning": inst.metrics.memoryLeakWarning,
        ]}
        return json(["servers": servers, "appVersion": "1.0.0", "language": manager.appLanguage.rawValue])
    }

    @MainActor
    private func handleServers() -> Data {
        guard let manager else { return resp(503, #"{"error":"not ready"}"#) }
        let list: [[String: Any]] = manager.profiles.map { profile in
            let inst = manager.instances[profile.id]
            return [
                "id":          profile.id.uuidString,
                "name":        profile.name,
                "path":        profile.path,
                "status":      inst?.status.apiString ?? "stopped",
                "playerCount": inst?.onlinePlayers.count ?? 0,
                "maxPlayers":  Int(profile.maxPlayers) ?? 20,
                "port":        Int(profile.serverPort) ?? 25565,
                "jar":         profile.jarName ?? "",
                "version":     profile.minecraftVersion.description,
            ]
        }
        return json(["servers": list])
    }

    @MainActor
    private func handleLogs(id: String) -> Data {
        guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
        let logList = inst.logs.suffix(200).map { entry -> [String: String] in [
            "time":    entry.time,
            "level":   entry.level.badge.trimmingCharacters(in: .whitespaces),
            "message": entry.message.isEmpty ? entry.raw : entry.message,
        ]}
        return json(["logs": logList, "total": inst.logs.count])
    }

    @MainActor
    private func handlePlayers(id: String) -> Data {
        guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
        return json(["players": inst.onlinePlayers, "count": inst.onlinePlayers.count])
    }

    @MainActor
    private func handleMetrics(id: String) -> Data {
        guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
        return json([
            "memoryMB": inst.metrics.memoryMB,
            "cpuPercent": inst.metrics.cpuPercent,
            "latencyMS": inst.metrics.latencyMS.map { $0 as Any } ?? NSNull(),
            "tps": inst.metrics.tps.map { $0 as Any } ?? NSNull(),
            "mspt": inst.metrics.mspt.map { $0 as Any } ?? NSNull(),
            "lagMS": inst.metrics.lagMS,
            "memoryLeakWarning": inst.metrics.memoryLeakWarning,
            "updatedAt": inst.metrics.updatedAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull()
        ])
    }

    @MainActor
    private func handleSettingsGet(id: String) -> Data {
        guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
        let p = inst.profile
        return json(["settings": [
            "motd": p.motd,
            "maxPlayers": Int(p.maxPlayers) ?? 20,
            "serverPort": Int(p.serverPort) ?? 25565,
            "viewDistance": Int(p.readProperty("view-distance", default: "10")) ?? 10,
            "simulationDistance": Int(p.readProperty("simulation-distance", default: "10")) ?? 10,
            "onlineMode": p.readProperty("online-mode", default: "true") == "true",
            "whitelistEnabled": p.whitelistEnabled,
            "version": p.minecraftVersion.description,
            "requiredJava": p.minecraftVersion.requiredJavaMajor
        ]])
    }

    @MainActor
    private func handleWhitelistGet(id: String) -> Data {
        guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
        let wl: [WhitelistEntry] = UserFiles.load("whitelist.json", from: inst.profile.path)
        let pending: [PendingWhitelistEntry] = UserFiles.load("pending_whitelist.json", from: inst.profile.path)
        let wlData = wl.map { ["uuid": $0.uuid, "name": $0.name, "pending": false] as [String: Any] }
        let pData  = pending.map { ["uuid": "", "name": $0.name, "pending": true, "command": $0.command] as [String: Any] }
        return json(["whitelist": wlData + pData])
    }

    @MainActor
    private func handleOpsGet(id: String) -> Data {
        guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
        let ops: [OpsEntry] = UserFiles.load("ops.json", from: inst.profile.path)
        let data = ops.map { ["uuid": $0.uuid, "name": $0.name, "level": $0.level] as [String: Any] }
        return json(["ops": data])
    }

    @MainActor
    private func handleBansGet(id: String) -> Data {
        guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
        let bans: [BanEntry] = UserFiles.load("banned-players.json", from: inst.profile.path)
        let data = bans.map { ["uuid": $0.uuid ?? "", "name": $0.name ?? "", "reason": $0.reason ?? ""] as [String: Any] }
        return json(["bans": data])
    }

    private func instanceAction(_ id: String,
                                _ action: @escaping @Sendable @MainActor (ServerInstance) -> Void) async -> Data {
        await MainActor.run { [weak self] in
            guard let self else { return Data() }
            guard let inst = self.findInstance(id) else { return self.resp(404, #"{"error":"server not found"}"#) }
            action(inst)
            return self.json(["ok": true])
        }
    }

    private func handleCommand(id: String, body: String) async -> Data {
        await MainActor.run {
            guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
            guard inst.status == .running else { return resp(409, #"{"error":"server not running"}"#) }
            guard let cmd = parseJSON(body)?["command"] as? String, !cmd.isEmpty else {
                return resp(400, #"{"error":"missing command"}"#)
            }
            guard cmd.utf8.count <= 512, !cmd.contains("\n"), !cmd.contains("\r") else {
                return resp(400, #"{"error":"invalid command"}"#)
            }
            inst.sendCommand(cmd)
            return json(["ok": true, "command": cmd])
        }
    }

    private func handleWhitelistAdd(id: String, body: String) async -> Data {
        await MainActor.run {
            guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
            guard let name = parseJSON(body)?["name"] as? String, !name.isEmpty else {
                return resp(400, #"{"error":"missing name"}"#)
            }
            guard UserFiles.isValidPlayerName(name) else { return resp(400, #"{"error":"invalid player name"}"#) }
            let path = inst.profile.path

            if inst.status == .running {
                let prefix = UserFiles.floodgatePrefix(in: path)
                let isBedrock = name.hasPrefix(prefix)
                if isBedrock {
                    let gameTag = UserFiles.stripFloodgatePrefix(from: name, in: path)
                    inst.sendCommand("fwhitelist add \(gameTag)")
                    return json(["ok": true, "method": "fwhitelist command"])
                } else {
                    inst.sendCommand("whitelist add \(name)")
                    inst.sendCommand("whitelist reload")
                    return json(["ok": true, "method": "whitelist command"])
                }
            }

            // Offline: resolve UUID
            if let resolved = UserFiles.resolvePlayer(name: name, in: path) {
                var wl: [WhitelistEntry] = UserFiles.load("whitelist.json", from: path)
                guard !wl.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
                    return json(["ok": false, "reason": "already exists"])
                }
                wl.append(WhitelistEntry(uuid: resolved.uuid, name: name))
                UserFiles.save(wl, filename: "whitelist.json", to: path)
                return json(["ok": true, "method": resolved.note])
            } else {
                // Bedrock pending
                let prefix = UserFiles.floodgatePrefix(in: path)
                let beName  = name.hasPrefix(prefix) ? name : prefix + name
                let gameTag = UserFiles.stripFloodgatePrefix(from: beName, in: path)
                var pending: [PendingWhitelistEntry] = UserFiles.load("pending_whitelist.json", from: path)
                pending.append(PendingWhitelistEntry(name: beName, command: "fwhitelist add \(gameTag)", addedAt: Date()))
                UserFiles.save(pending, filename: "pending_whitelist.json", to: path)
                return json(["ok": true, "method": "pending (bedrock)"])
            }
        }
    }

    private func handleWhitelistEnabled(id: String, body: String) async -> Data {
        await MainActor.run {
            guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
            guard let enabled = parseJSON(body)?["enabled"] as? Bool else { return resp(400, #"{"error":"missing enabled"}"#) }
            guard inst.profile.writeProperties(["white-list": enabled ? "true" : "false"]) else {
                return resp(500, #"{"error":"cannot write server.properties"}"#)
            }
            if inst.status == .running { inst.sendCommand("whitelist \(enabled ? "on" : "off")") }
            return json(["ok": true, "enabled": enabled])
        }
    }

    private func handleSettingsUpdate(id: String, body: String) async -> Data {
        await MainActor.run {
            guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
            guard inst.status == .stopped else { return resp(409, #"{"error":"stop server before changing settings"}"#) }
            guard let input = parseJSON(body) else { return resp(400, #"{"error":"invalid json"}"#) }
            var changes: [String: String] = [:]
            if let value = input["motd"] as? String { changes["motd"] = String(value.prefix(160)).replacingOccurrences(of: "\n", with: " ") }
            if let value = input["maxPlayers"] as? Int, (1...10000).contains(value) { changes["max-players"] = String(value) }
            if let value = input["serverPort"] as? Int, (1...65535).contains(value) { changes["server-port"] = String(value) }
            if let value = input["viewDistance"] as? Int, (2...32).contains(value) { changes["view-distance"] = String(value) }
            if let value = input["simulationDistance"] as? Int, (2...32).contains(value) { changes["simulation-distance"] = String(value) }
            if let value = input["onlineMode"] as? Bool { changes["online-mode"] = value ? "true" : "false" }
            guard !changes.isEmpty else { return resp(400, #"{"error":"no valid settings"}"#) }
            guard inst.profile.writeProperties(changes) else { return resp(500, #"{"error":"cannot write server.properties"}"#) }
            return json(["ok": true, "restartRequired": true])
        }
    }

    private func handleServerDelete(id: String) async -> Data {
        await MainActor.run {
            guard let uuid = UUID(uuidString: id), let manager else { return resp(404, #"{"error":"server not found"}"#) }
            guard manager.removeProfile(id: uuid) else { return resp(409, #"{"error":"stop server before removing it"}"#) }
            return json(["ok": true, "filesDeleted": false])
        }
    }

    private func handleWhitelistDelete(id: String, uuid: String) async -> Data {
        await MainActor.run {
            guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
            let path = inst.profile.path
            var wl: [WhitelistEntry] = UserFiles.load("whitelist.json", from: path)
            let before = wl.count
            if let entry = wl.first(where: { $0.uuid == uuid }) {
                if inst.status == .running {
                    inst.sendCommand("whitelist remove \(entry.name)")
                    inst.sendCommand("whitelist reload")
                } else {
                    wl.removeAll { $0.uuid == uuid }
                    UserFiles.save(wl, filename: "whitelist.json", to: path)
                }
            }
            return json(["ok": wl.count < before || inst.status == .running])
        }
    }

    private func handleOpsAdd(id: String, body: String) async -> Data {
        await MainActor.run {
            guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
            guard let name = parseJSON(body)?["name"] as? String, !name.isEmpty else {
                return resp(400, #"{"error":"missing name"}"#)
            }
            guard UserFiles.isValidPlayerName(name) else { return resp(400, #"{"error":"invalid player name"}"#) }
            let path = inst.profile.path
            if inst.status == .running {
                inst.sendCommand("op \(name)")
                return json(["ok": true, "method": "command"])
            }
            if let resolved = UserFiles.resolvePlayer(name: name, in: path) {
                var ops: [OpsEntry] = UserFiles.load("ops.json", from: path)
                guard !ops.contains(where: { $0.uuid == resolved.uuid }) else {
                    return json(["ok": false, "reason": "already op"])
                }
                ops.append(OpsEntry(uuid: resolved.uuid, name: name, level: 4, bypassesPlayerLimit: false))
                UserFiles.save(ops, filename: "ops.json", to: path)
                return json(["ok": true, "method": resolved.note])
            }
            return resp(422, #"{"error":"cannot resolve uuid (bedrock not cached)"}"#)
        }
    }

    private func handleOpsDelete(id: String, uuid: String) async -> Data {
        await MainActor.run {
            guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
            let path = inst.profile.path
            var ops: [OpsEntry] = UserFiles.load("ops.json", from: path)
            if let entry = ops.first(where: { $0.uuid == uuid }) {
                if inst.status == .running {
                    inst.sendCommand("deop \(entry.name)")
                } else {
                    ops.removeAll { $0.uuid == uuid }
                    UserFiles.save(ops, filename: "ops.json", to: path)
                }
            }
            return json(["ok": true])
        }
    }

    private func handlePardon(id: String, playerName: String) async -> Data {
        await MainActor.run {
            guard let inst = findInstance(id) else { return resp(404, #"{"error":"server not found"}"#) }
            guard let decodedName = playerName.removingPercentEncoding,
                  UserFiles.isValidPlayerName(decodedName) else { return resp(400, #"{"error":"invalid player name"}"#) }
            let path = inst.profile.path
            if inst.status == .running {
                inst.sendCommand("pardon \(decodedName)")
            } else {
                var bans: [BanEntry] = UserFiles.load("banned-players.json", from: path)
                bans.removeAll { $0.name?.lowercased() == decodedName.lowercased() }
                UserFiles.save(bans, filename: "banned-players.json", to: path)
            }
            return json(["ok": true])
        }
    }

    // MARK: - HTML response helper

    private func respHTML(_ html: String) -> Data {
        let bodyData = html.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 200 OK\r\n" +
                     "Content-Type: text/html; charset=utf-8\r\n" +
                     "Content-Length: \(bodyData.count)\r\n" +
                     corsHeaders +
                     "Connection: close\r\n\r\n"
        return Data(header.utf8) + bodyData
    }

    // MARK: - Built-in Web UI (served at GET /, works on iPad Safari over plain HTTP)

    private static let webUI = """
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MCSManager</title>
<style>
:root{--bg:#18181b;--card:#27272a;--border:#3f3f46;--text:#e4e4e7;--sub:#71717a;--green:#4ade80;--yellow:#facc15;--red:#f87171;--blue:#60a5fa;--orange:#fb923c;--teal:#2dd4bf}
@media(prefers-color-scheme:light){:root{--bg:#f4f4f5;--card:#fff;--border:#e4e4e7;--text:#18181b;--sub:#71717a}}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:-apple-system,sans-serif;font-size:14px;padding:12px;max-width:640px;margin:0 auto}
h1{font-size:17px;font-weight:700;margin-bottom:12px;display:flex;align-items:center;gap:8px}
.card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:12px;margin-bottom:10px}
.row{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.dot{width:9px;height:9px;border-radius:50%;flex-shrink:0}
.g{background:var(--green)}.y{background:var(--yellow)}.r{background:var(--sub)}
.name{font-weight:600;font-size:15px;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sub{font-size:12px;color:var(--sub)}
.badge{font-size:11px;padding:2px 7px;border-radius:20px;font-weight:500;white-space:nowrap}
.badge-run{background:rgba(74,222,128,.15);color:var(--green);border:1px solid rgba(74,222,128,.3)}
.badge-start{background:rgba(250,204,21,.15);color:var(--yellow);border:1px solid rgba(250,204,21,.3)}
.badge-stop{background:rgba(113,113,122,.15);color:var(--sub);border:1px solid rgba(113,113,122,.3)}
.badge-stopping{background:rgba(251,146,60,.15);color:var(--orange);border:1px solid rgba(251,146,60,.3)}
.btn{padding:6px 14px;border-radius:8px;border:1px solid var(--border);background:var(--card);color:var(--text);cursor:pointer;font-size:12px;font-weight:500;-webkit-tap-highlight-color:transparent}
.btn:active{opacity:.7}
.btn-g{background:rgba(74,222,128,.12);border-color:rgba(74,222,128,.35);color:var(--green)}
.btn-r{background:rgba(248,113,113,.12);border-color:rgba(248,113,113,.35);color:var(--red)}
.btn-b{background:rgba(96,165,250,.12);border-color:rgba(96,165,250,.35);color:var(--blue)}
.btn-o{background:rgba(251,146,60,.12);border-color:rgba(251,146,60,.35);color:var(--orange)}
.players{display:flex;flex-wrap:wrap;gap:4px;margin-top:8px}
.player{background:rgba(74,222,128,.1);border:1px solid rgba(74,222,128,.25);border-radius:12px;padding:2px 9px;font-size:11px;color:var(--green)}
input[type=text],input[type=password],select{padding:9px 11px;border-radius:9px;border:1px solid var(--border);background:var(--card);color:var(--text);font-size:14px;width:100%;-webkit-appearance:none;appearance:none}
select{background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='8'%3E%3Cpath d='M1 1l5 5 5-5' stroke='%2371717a' stroke-width='1.5' fill='none'/%3E%3C/svg%3E");background-repeat:no-repeat;background-position:right 10px center;padding-right:30px}
#login{display:none;text-align:center;padding:60px 20px}
#login h2{margin-bottom:20px;font-size:20px}
#login input{margin-bottom:12px;text-align:center}
#login .btn{width:100%;padding:12px;font-size:15px;margin-top:4px}
#flash{padding:9px 12px;border-radius:9px;margin-bottom:10px;font-size:12px;display:none;border:1px solid}
.cmd-bar{display:flex;gap:8px;margin-top:8px}
.cmd-bar input{flex:1}
.cmd-bar .btn{white-space:nowrap}
.srv-btns{display:flex;gap:6px;flex-wrap:wrap;margin-top:10px}
#refresh-indicator{font-size:11px;color:var(--sub);margin-left:auto}
</style>
</head>
<body>
<div id="login">
  <h2>&#x1F512; 認証</h2>
  <input type="password" id="pw" placeholder="パスワード" autocomplete="current-password">
  <button class="btn btn-b" onclick="login()">ログイン</button>
  <p id="login-err" style="margin-top:10px;font-size:12px;color:var(--red)"></p>
</div>
<div id="app" style="display:none">
  <h1>&#x1F9CA; MCSManager <span id="ver" class="sub" style="font-size:12px;font-weight:400;margin-left:4px"></span><span id="refresh-indicator">●</span></h1>
  <div id="flash"></div>
  <div id="servers"></div>
  <div class="card">
    <div class="sub" style="margin-bottom:8px">&#x1F4BB; コンソールコマンド</div>
    <select id="cmd-srv"></select>
    <div class="cmd-bar" style="margin-top:8px">
      <input type="text" id="cmd" placeholder="コマンドを入力..." autocomplete="off" autocorrect="off" autocapitalize="none" spellcheck="false">
      <button class="btn btn-b" onclick="sendCmd()">送信</button>
    </div>
  </div>
</div>
<script>
var pw=sessionStorage.getItem('mcs_pw')||'';
var refreshTimer=null;

async function api(method,path,body){
  var h={'Content-Type':'application/json'};
  if(pw)h['Authorization']='Bearer '+pw;
  var opts={method:method,headers:h};
  if(body)opts.body=JSON.stringify(body);
  try{
    var r=await fetch(path,opts);
    if(r.status===401){showLogin();return null;}
    return await r.json();
  }catch(e){flash('接続エラー: '+e.message,1);return null;}
}

async function refresh(){
  document.getElementById('refresh-indicator').style.color='var(--sub)';
  var data=await api('GET','/api/status');
  if(!data)return;
  document.getElementById('refresh-indicator').style.color='var(--green)';
  setTimeout(function(){document.getElementById('refresh-indicator').style.color='var(--sub)';},800);
  document.getElementById('ver').textContent='v'+(data.appVersion||'');
  var srvs=data.servers||[];
  var sel=document.getElementById('cmd-srv');
  var prev=sel.value;
  sel.innerHTML=srvs.map(function(s){return '<option value="'+s.id+'">'+esc(s.name)+'</option>';}).join('');
  if(prev&&srvs.find(function(s){return s.id===prev;}))sel.value=prev;
  var c=document.getElementById('servers');
  c.innerHTML=srvs.map(function(s){
    var labels={stopped:'停止中',starting:'起動中...',running:'稼働中',stopping:'停止処理中...'};
    var bclass={stopped:'badge-stop',starting:'badge-start',running:'badge-run',stopping:'badge-stopping'};
    var dclass={stopped:'r',starting:'y',running:'g',stopping:'y'};
    var lbl=labels[s.status]||s.status;
    var btns='';
    if(s.status==='stopped')btns='<button class="btn btn-g" onclick="act(\''+s.id+'\',\'start\')">&#x25B6; 起動</button>';
    if(s.status==='running'||s.status==='starting')btns='<button class="btn btn-r" onclick="act(\''+s.id+'\',\'stop\')">&#x25A0; 停止</button><button class="btn btn-o" onclick="act(\''+s.id+'\',\'restart\')">&#x21BB; 再起動</button>';
    var players='';
    if(s.playerCount>0)players='<div class="players" id="pl-'+s.id+'"><span class="sub">プレイヤー読込中...</span></div>';
    return '<div class="card"><div class="row"><span class="dot '+dclass[s.status]||'r'+'"></span><span class="name">'+esc(s.name)+'</span><span class="badge '+bclass[s.status]||'badge-stop'+'">'+lbl+'</span></div>'
      +'<div class="sub" style="margin-top:5px">port '+s.port+'　最大'+s.maxPlayers+'人</div>'
      +players
      +'<div class="srv-btns">'+btns+'<button class="btn" onclick="showLogs(\''+s.id+'\',\''+esc(s.name)+'\')">&#x1F4DC; ログ</button></div></div>';
  }).join('');
  // Load players for running servers
  srvs.filter(function(s){return s.status==='running'&&s.playerCount>0;}).forEach(function(s){loadPlayers(s.id);});
  document.getElementById('app').style.display='';
  document.getElementById('login').style.display='none';
}

async function loadPlayers(id){
  var data=await api('GET','/api/servers/'+id+'/players');
  if(!data)return;
  var el=document.getElementById('pl-'+id);
  if(!el)return;
  if(data.players&&data.players.length>0){
    el.innerHTML=data.players.map(function(n){return '<span class="player">'+esc(n)+'</span>';}).join('');
  }else{
    el.innerHTML='<span class="sub">プレイヤーなし</span>';
  }
}

async function act(id,action){
  var data=await api('POST','/api/servers/'+id+'/'+action);
  if(data&&data.ok){var m={start:'起動中...',stop:'停止処理中...',restart:'再起動中...'};flash(m[action]||action);}
  setTimeout(refresh,1500);
}

async function sendCmd(){
  var id=document.getElementById('cmd-srv').value;
  var cmd=document.getElementById('cmd').value.trim();
  if(!id||!cmd)return;
  var data=await api('POST','/api/servers/'+id+'/command',{command:cmd});
  if(data&&data.ok){flash('&#x2705; コマンド送信: '+esc(cmd));document.getElementById('cmd').value='';}
}

function showLogs(id,name){
  api('GET','/api/servers/'+id+'/logs').then(function(data){
    if(!data)return;
    var txt=(data.logs||[]).slice(-50).map(function(l){return (l.time?l.time+' ':'')+l.message;}).join('\\n');
    var w=window.open('','_blank','width=600,height=500');
    if(w){w.document.write('<html><head><title>ログ - '+name+'</title><style>body{background:#18181b;color:#e4e4e7;font-family:monospace;font-size:12px;padding:12px;white-space:pre-wrap;word-break:break-all}</style></head><body>'+esc(txt)+'</body></html>');w.document.close();}
  });
}

function flash(msg,isErr){
  var el=document.getElementById('flash');
  el.innerHTML=msg;el.style.display='';
  el.style.background=isErr?'rgba(248,113,113,.1)':'rgba(96,165,250,.1)';
  el.style.borderColor=isErr?'rgba(248,113,113,.35)':'rgba(96,165,250,.35)';
  el.style.color=isErr?'var(--red)':'var(--blue)';
  clearTimeout(el._t);el._t=setTimeout(function(){el.style.display='none';},3500);
}

function showLogin(){
  document.getElementById('app').style.display='none';
  document.getElementById('login').style.display='';
}

function login(){
  pw=document.getElementById('pw').value;
  sessionStorage.setItem('mcs_pw',pw);
  refresh().then(function(){
    if(document.getElementById('app').style.display!=='none')return;
    document.getElementById('login-err').textContent='パスワードが違います';
    pw='';sessionStorage.removeItem('mcs_pw');
  });
}

function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}

document.getElementById('pw').addEventListener('keydown',function(e){if(e.key==='Enter')login();});
document.getElementById('cmd').addEventListener('keydown',function(e){if(e.key==='Enter')sendCmd();});

refresh();
refreshTimer=setInterval(refresh,5000);
</script>
</body>
</html>
"""

    // MARK: - Helpers

    @MainActor
    private func findInstance(_ id: String) -> ServerInstance? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return manager?.instances[uuid]
    }

    private func parseJSON(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func json(_ dict: [String: Any]) -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .sortedKeys) else {
            return resp(500, #"{"error":"serialization failed"}"#)
        }
        return resp(200, String(data: data, encoding: .utf8) ?? "{}")
    }

    private let corsHeaders =
        "Access-Control-Allow-Origin: *\r\n" +
        "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n" +
        "Access-Control-Allow-Headers: Authorization, Content-Type\r\n" +
        "X-Content-Type-Options: nosniff\r\n" +
        "X-Frame-Options: DENY\r\n" +
        "Referrer-Policy: no-referrer\r\n"

    private func resp(_ status: Int, _ body: String) -> Data {
        let text: String
        switch status {
        case 200: text = "OK"
        case 201: text = "Created"
        case 400: text = "Bad Request"
        case 401: text = "Unauthorized"
        case 404: text = "Not Found"
        case 409: text = "Conflict"
        case 413: text = "Payload Too Large"
        case 429: text = "Too Many Requests"
        case 503: text = "Service Unavailable"
        case 422: text = "Unprocessable Entity"
        default:  text = "Internal Server Error"
        }
        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status) \(text)\r\n" +
                     "Content-Type: application/json; charset=utf-8\r\n" +
                     "Content-Length: \(bodyData.count)\r\n" +
                     corsHeaders +
                     "Connection: close\r\n\r\n"
        return Data(header.utf8) + bodyData
    }
}
