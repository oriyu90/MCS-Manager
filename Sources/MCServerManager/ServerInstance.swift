import Foundation
import SwiftUI
import UserNotifications
import Darwin

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func appendAndDrain(_ incoming: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(incoming)
        var lines: [String] = []
        while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            if let line = String(data: data[data.startIndex..<newline], encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
            data.removeSubrange(data.startIndex...newline)
        }
        return lines
    }
}

// Per-server process manager. One instance per ServerProfile.
@MainActor
final class ServerInstance: ObservableObject, Identifiable {

    // MARK: - Identity
    let id: UUID  // stored separately so Identifiable is nonisolated-safe
    @Published var profile: ServerProfile

    // MARK: - State
    @Published var status: ServerStatus = .stopped
    @Published var logs:   [LogEntry]   = []
    @Published var onlinePlayers: [String] = []
    @Published var startTime: Date?
    @Published var uptime: TimeInterval = 0
    @Published var metrics = ServerMetrics()

    // MARK: - Private
    private var process:    Process?
    private var stdinPipe:  Pipe?
    private var uptimeTimer: Timer?
    private var metricsTimer: Timer?
    private var memorySamples: [(Date, Double)] = []
    private var metricsTick = 0
    private var metricsSampleInFlight = false
    private var restartAfterStop = false
    private var detachedPID: Int32?
    private var launchGeneration = 0

    private var pidFileURL: URL {
        URL(fileURLWithPath: profile.path).appendingPathComponent(".mcsmanager.pid")
    }

    init(profile: ServerProfile) {
        self.id      = profile.id
        self.profile = profile
        detectDetachedProcess()
    }

    // MARK: - Control

    func start() {
        guard status.canStart else { return }
        launchGeneration += 1
        status = .starting
        logs.removeAll()
        onlinePlayers.removeAll()
        startTime = nil
        uptime    = 0
        metrics = ServerMetrics()
        memorySamples.removeAll()
        metricsTick = 0
        appendLog("▶ \(profile.name) を起動します...")

        let proc = Process()
        let stdoutPipe = Pipe()
        let stdin = Pipe()

        if profile.hasStartScript {
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [profile.path + "/start.sh"]
        } else if let jar = profile.jarName {
            guard let java = findJavaBin(requiredMajor: profile.minecraftVersion.requiredJavaMajor) else {
                status = .stopped
                appendLog("❌ Minecraft \(profile.minecraftVersion) には Java \(profile.minecraftVersion.requiredJavaMajor) 以上が必要です")
                return
            }
            let physicalMB = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
            let maxHeapMB = max(1024, min(8192, physicalMB / 2))
            let initialHeapMB = min(2048, maxHeapMB)
            let baseArgs = ["-Xms\(initialHeapMB)M", "-Xmx\(maxHeapMB)M",
                            "-XX:+UseG1GC", "-XX:MaxGCPauseMillis=200"]
            let extra = profile.jvmArgs.components(separatedBy: " ").filter { !$0.isEmpty }
            proc.executableURL = URL(fileURLWithPath: java)
            // Custom JVM arguments come last so a profile can override memory/GC defaults.
            proc.arguments = baseArgs + extra + ["-jar", profile.path + "/" + jar, "nogui"]
        } else {
            status = .stopped
            appendLog("❌ 起動に必要な JAR ファイルが見つかりません: \(profile.path)")
            return
        }

        proc.currentDirectoryURL = URL(fileURLWithPath: profile.path)
        proc.standardOutput = stdoutPipe
        proc.standardError  = stdoutPipe
        proc.standardInput  = stdin

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.handleTermination(code: p.terminationStatus)
            }
        }

        self.process   = proc
        self.stdinPipe = stdin
        startReading(pipe: stdoutPipe)

        do {
            try proc.run()
            persistPID(proc.processIdentifier)
            startMetricsTimer()
        } catch {
            status = .stopped
            appendLog("❌ 起動失敗: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard status.canStop else { return }
        status = .stopping
        sendCommand("stop")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            if self?.status == .stopping {
                self?.process?.terminate()
            }
        }
    }

    func forceKill() {
        let pid = process?.processIdentifier ?? detachedPID
        guard let pid, pid > 0 else { return }
        Darwin.kill(pid, SIGKILL)
        if process == nil {
            detachedPID = nil
            status = .stopped
            removePersistedPID(ifMatching: pid)
            metricsTimer?.invalidate(); metricsTimer = nil
            metrics = ServerMetrics()
        }
    }

    func requestGracefulShutdown() {
        switch status {
        case .running, .starting:
            stop()
        case .orphaned:
            appendLog("⚠️ 外部プロセスはコンソールへ接続できないため、自動停止できません")
        case .stopped, .stopping:
            break
        }
    }

    func restart() {
        guard status.canStop else { start(); return }
        restartAfterStop = true
        stop()
    }

    func sendCommand(_ cmd: String) {
        guard let pipe = stdinPipe else { return }
        let data = (cmd + "\n").data(using: .utf8)!
        try? pipe.fileHandleForWriting.write(contentsOf: data)
    }

    // MARK: - Private

    private func startReading(pipe: Pipe) {
        let buf = LineBuffer()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let incoming = handle.availableData
            guard !incoming.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = buf.appendAndDrain(incoming)
            guard !lines.isEmpty else { return }

            Task { @MainActor [weak self] in
                lines.forEach { self?.processLine($0) }
            }
        }
    }

    private func processLine(_ raw: String) {
        let entry = LogEntry(raw: raw)
        logs.append(entry)
        if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }

        let msg = entry.message.isEmpty ? raw : entry.message
        parsePerformanceLine(msg)

        if msg.contains("Done (") && msg.contains("For help") {
            status    = .running
            startTime = Date()
            startUptimeTimer()
            processPendingWhitelist()
            notify(title: "サーバー起動完了", body: "\(profile.name) が起動しました")
        }

        switch LogParsing.playerEvent(from: msg) {
        case .joined(let name):
            if !onlinePlayers.contains(name) { onlinePlayers.append(name) }
            notify(title: "参加", body: "\(name) が参加しました (\(profile.name))")
        case .left(let name):
            onlinePlayers.removeAll { $0 == name }
        case .none:
            break
        }
    }

    private func handleTermination(code: Int32) {
        launchGeneration += 1
        uptimeTimer?.invalidate(); uptimeTimer = nil
        metricsTimer?.invalidate(); metricsTimer = nil
        metricsSampleInFlight = false

        if status == .stopping {
            appendLog("■ サーバーが停止しました")
            notify(title: "サーバー停止", body: "\(profile.name) が停止しました")
        } else {
            appendLog("⚠️ サーバーが予期せず終了しました (exit \(code))")
            notify(title: "サーバークラッシュ", body: "\(profile.name) が予期せず終了 (exit \(code))")
        }

        status        = .stopped
        onlinePlayers = []
        startTime     = nil
        uptime        = 0
        metrics       = ServerMetrics()
        let terminatedPID = process?.processIdentifier
        process       = nil
        stdinPipe     = nil
        if let terminatedPID { removePersistedPID(ifMatching: terminatedPID) }

        if restartAfterStop {
            restartAfterStop = false
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.start()
            }
        }
    }

    private func appendLog(_ raw: String) {
        logs.append(LogEntry(raw: raw))
    }

    private func startUptimeTimer() {
        uptimeTimer?.invalidate()
        let t0 = Date()
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.uptime = Date().timeIntervalSince(t0)
            }
        }
    }

    // When server starts, run any pending whitelist commands (Bedrock players added offline)
    private func processPendingWhitelist() {
        let pending: [PendingWhitelistEntry] = UserFiles.load("pending_whitelist.json", from: profile.path)
        guard !pending.isEmpty else { return }
        let generation = launchGeneration

        for (i, entry) in pending.enumerated() {
            // Stagger commands 3s after start, 0.5s apart
            let delay = 3.0 + Double(i) * 0.5
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                await MainActor.run { [weak self] in
                    guard let self, self.launchGeneration == generation, self.status == .running else { return }
                    self.sendCommand(entry.command)
                }
            }
        }

        // After all commands, reload whitelist and clear pending file
        Task { [weak self] in
            let reloadDelay = 4.0 + Double(pending.count) * 0.5
            try? await Task.sleep(for: .seconds(reloadDelay))
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.launchGeneration == generation, self.status == .running else { return }
                self.sendCommand("whitelist reload")
                UserFiles.save([PendingWhitelistEntry](), filename: "pending_whitelist.json", to: self.profile.path)
                self.appendLog("[システム] 保留中のホワイトリスト \(pending.count) 件を適用しました")
            }
        }
    }

    private func findJavaBin(requiredMajor: Int) -> String? {
        var candidates: [String] = []
        if let javaHome = ProcessInfo.processInfo.environment["JAVA_HOME"], !javaHome.isEmpty {
            candidates.append(javaHome + "/bin/java")
        }
        if let managedJava = Self.javaHomeExecutable(requiredMajor: requiredMajor) {
            candidates.append(managedJava)
        }
        candidates += [
            "/opt/homebrew/opt/openjdk@\(requiredMajor)/bin/java",
            "/usr/local/opt/openjdk@\(requiredMajor)/bin/java",
            "/opt/homebrew/opt/openjdk/bin/java",
            "/usr/local/opt/openjdk/bin/java",
            "/usr/bin/java"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if Self.javaMajor(at: candidate) >= requiredMajor { return candidate }
        }
        return nil
    }

    nonisolated private static func javaHomeExecutable(requiredMajor: Int) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        process.arguments = ["-v", "\(requiredMajor)+"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let home = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let home, !home.isEmpty else { return nil }
        return home + "/bin/java"
    }

    nonisolated private static func javaMajor(at path: String) -> Int {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = ["-version"]
        p.standardError = pipe; p.standardOutput = pipe
        guard (try? p.run()) != nil else { return 0 }
        p.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let regex = try? NSRegularExpression(pattern: #"version \"(?:1\.)?(\d+)"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return 0 }
        return Int(text[range]) ?? 0
    }

    private func startMetricsTimer() {
        metricsTimer?.invalidate()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleMetrics() }
        }
        sampleMetrics()
    }

    private func sampleMetrics() {
        guard !metricsSampleInFlight else { return }
        guard let pid = process?.processIdentifier ?? detachedPID, pid > 0 else { return }
        metricsSampleInFlight = true
        let port = Int(profile.serverPort) ?? 25565
        metricsTick += 1
        if metricsTick % 6 == 0, status == .running {
            let plugins = (try? FileManager.default.contentsOfDirectory(atPath: profile.path + "/plugins")) ?? []
            sendCommand(plugins.contains(where: { $0.lowercased().hasPrefix("spark") }) ? "spark tps --no-colors" : "tps")
        }
        Task.detached { [weak self] in
            let sampled = Self.readProcessMetrics(pid: pid, port: port)
            await MainActor.run { [weak self] in
                guard let self else { return }
                defer { self.metricsSampleInFlight = false }
                guard self.process?.processIdentifier == pid || self.detachedPID == pid else { return }
                self.metrics.memoryMB = sampled.memory
                self.metrics.cpuPercent = sampled.cpu
                self.metrics.latencyMS = sampled.latency
                self.metrics.updatedAt = Date()
                self.memorySamples.append((Date(), sampled.memory))
                self.memorySamples.removeAll { Date().timeIntervalSince($0.0) > 600 }
                if self.memorySamples.count >= 24 {
                    self.metrics.memoryLeakWarning = MetricsAnalysis.hasSustainedMemoryGrowth(self.memorySamples)
                }
            }
        }
    }

    nonisolated private static func readProcessMetrics(pid: Int32, port: Int) -> (memory: Double, cpu: Double, latency: Double?) {
        let ps = Process(); let out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "rss=,%cpu=", "-p", String(pid)]
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return (0, 0, nil) }
        ps.waitUntilExit()
        let fields = (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .split(whereSeparator: { $0.isWhitespace })
        let memory = (fields.first.flatMap { Double($0) } ?? 0) / 1024.0
        let cpu = fields.dropFirst().first.flatMap { Double($0) } ?? 0
        let start = Date(); let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        probe.arguments = ["-z", "-G", "1", "127.0.0.1", String(port)]
        guard (try? probe.run()) != nil else { return (memory, cpu, nil) }
        probe.waitUntilExit()
        let latency = probe.terminationStatus == 0 ? Date().timeIntervalSince(start) * 1000 : nil
        return (memory, cpu, latency)
    }

    private func parsePerformanceLine(_ message: String) {
        func firstValue(after label: String) -> Double? {
            let escaped = NSRegularExpression.escapedPattern(for: label)
            let pattern = escaped + #"[^:]*:\s*\*?([0-9]+(?:\.[0-9]+)?)"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let valueRange = Range(match.range(at: 1), in: message) else { return nil }
            return Double(message[valueRange])
        }
        if let tps = firstValue(after: "TPS") { metrics.tps = min(20, max(0, tps)) }
        if let mspt = firstValue(after: "MSPT") { metrics.mspt = max(0, mspt) }
        if message.localizedCaseInsensitiveContains("can't keep up") || message.localizedCaseInsensitiveContains("cannot keep up") {
            if let regex = try? NSRegularExpression(pattern: #"running\s+([0-9]+(?:\.[0-9]+)?)ms"#, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
               let range = Range(match.range(at: 1), in: message) {
                metrics.lagMS = Double(message[range]) ?? metrics.lagMS
            }
        } else if metrics.lagMS > 0 {
            metrics.lagMS *= 0.9
        }
    }

    private func persistPID(_ pid: Int32) {
        try? String(pid).write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private func removePersistedPID(ifMatching pid: Int32) {
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
              Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) == pid else { return }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private func detectDetachedProcess() {
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        if Darwin.kill(pid, 0) == 0, Self.process(pid: pid, belongsTo: profile.path) {
            detachedPID = pid
            status = .orphaned
            logs.append(LogEntry(raw: "⚠️ 前回のアプリ終了後もPID \(pid)が残っています。二重起動を防止しました"))
            startMetricsTimer()
        } else {
            try? FileManager.default.removeItem(at: pidFileURL)
        }
    }

    nonisolated private static func process(pid: Int32, belongsTo serverPath: String) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        let command = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return command.contains(serverPath)
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body  = body
        c.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
