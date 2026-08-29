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
        return json(["servers": servers, "appVersion": "1.1.0", "language": manager.appLanguage.rawValue])
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
