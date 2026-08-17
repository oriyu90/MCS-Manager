import Foundation
import SwiftUI
import AppKit
import UserNotifications
import Combine

@MainActor
final class ServerManager: ObservableObject {

    @Published var appLanguage: AppLanguage = .japanese {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage") }
    }

    // MARK: - Profiles & Instances
    @Published var profiles:  [ServerProfile]     = []
    @Published var instances: [UUID: ServerInstance] = [:]
    @Published var focusedProfileID: UUID?

    // MARK: - Web API Settings
    @Published var webAPIEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(webAPIEnabled, forKey: "webAPIEnabled")
            if webAPIEnabled { startWebAPI() } else { stopWebAPI() }
        }
    }
    @Published var webAPIPort: Int = 25580 {
        didSet { UserDefaults.standard.set(webAPIPort, forKey: "webAPIPort") }
    }
    @Published var webAPIPassword: String = "" {
        didSet { UserDefaults.standard.set(webAPIPassword, forKey: "webAPIPassword") }
    }
    @Published var webAPIRunning: Bool = false
    @Published var isQuitting: Bool = false
    private var httpServer: HTTPServer?

    // Combine: forward any instance change to manager so views re-render
    private var instanceSubs: [UUID: AnyCancellable] = [:]

    // MARK: - Computed helpers

    var focusedInstance: ServerInstance? {
        if let id = focusedProfileID, let inst = instances[id] { return inst }
        return instances.values.first(where: { $0.status == .running })
            ?? instances.values.first
    }

    var hasValidProfile: Bool {
        profiles.contains(where: { $0.isValid })
    }

    // Any server currently running?
    var anyRunning: Bool {
        instances.values.contains { $0.status == .running || $0.status == .starting }
    }

    // Backward-compat shims used by App.swift StatusBarIcon and some views
    var status: ServerStatus { focusedInstance?.status ?? .stopped }
    var logs: [LogEntry]     { focusedInstance?.logs ?? [] }
    var onlinePlayers: [String] { focusedInstance?.onlinePlayers ?? [] }
    var uptime: TimeInterval    { focusedInstance?.uptime ?? 0 }
    var startTime: Date?        { focusedInstance?.startTime }

    var activeProfile: ServerProfile {
        get {
            focusedInstance?.profile
                ?? profiles.first(where: { $0.isValid })
                ?? ServerProfile(name: "", path: "")
        }
        set {
            focusedProfileID = newValue.id
            if instances[newValue.id] == nil {
                let inst = ServerInstance(profile: newValue)
                instances[newValue.id] = inst
                observeInstance(inst)
            }
        }
    }

    // MARK: - Init

    init() {
        if let raw = UserDefaults.standard.string(forKey: "appLanguage"), let language = AppLanguage(rawValue: raw) {
            self.appLanguage = language
        }
        let loaded: [ServerProfile]
        if let data = UserDefaults.standard.data(forKey: "serverProfiles"),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data),
           !decoded.isEmpty {
            loaded = decoded
        } else {
            loaded = []
        }

        let activePath = UserDefaults.standard.string(forKey: "activeServerPath") ?? ""
        let active = loaded.first { $0.path == activePath }
            ?? loaded.first(where: { $0.isValid })
            ?? loaded.first

        self.profiles         = loaded
        self.focusedProfileID = active?.id

        // Create an instance for every known profile
        for profile in loaded {
            let inst = ServerInstance(profile: profile)
            instances[profile.id] = inst
        }

        // Load web API settings
        let savedPort = UserDefaults.standard.integer(forKey: "webAPIPort")
        self.webAPIPort     = savedPort > 0 ? savedPort : 25580
        self.webAPIPassword = UserDefaults.standard.string(forKey: "webAPIPassword") ?? ""
        // Note: webAPIEnabled loaded below to avoid triggering didSet before httpServer exists

        // Forward instance changes to manager (reactivity)
        for inst in instances.values { observeInstance(inst) }

        requestNotificationPermission()

        // Auto-start
        if let active, active.autoStartServer, let inst = instances[active.id] {
            Task { @MainActor [weak inst] in
                try? await Task.sleep(for: .milliseconds(800))
                inst?.start()
            }
        }

        // Enable web API after full init
        let apiEnabled = UserDefaults.standard.bool(forKey: "webAPIEnabled")
        if apiEnabled {
            self.webAPIEnabled = apiEnabled  // triggers didSet → startWebAPI()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.instances.values.forEach { $0.requestGracefulShutdown() }
            }
        }
    }

    // MARK: - Control (delegates to focused instance)

    func start() {
        if let inst = focusedInstance {
            inst.start()
        } else if let profile = profiles.first(where: { $0.isValid }) {
            startServer(profile: profile)
        }
    }

    func stop()      { focusedInstance?.stop() }
    func restart()   { focusedInstance?.restart() }
    func forceKill() { focusedInstance?.forceKill() }
    func sendCommand(_ cmd: String) { focusedInstance?.sendCommand(cmd) }
    func clearLogs() { focusedInstance?.logs.removeAll() }

    func quitApplication() {
        guard !isQuitting else { return }
        isQuitting = true
        instances.values.forEach { $0.requestGracefulShutdown() }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(30)
            while self.instances.values.contains(where: { $0.status != .stopped && $0.status != .orphaned }),
                  Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            // Only processes that did not complete Minecraft's normal stop sequence are killed.
            self.instances.values.filter { $0.status != .stopped }.forEach { $0.forceKill() }
            try? await Task.sleep(for: .milliseconds(500))
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Multi-server

    func startServer(profile: ServerProfile) {
        if let existing = instances[profile.id] {
            existing.start()
        } else {
            let inst = ServerInstance(profile: profile)
            instances[profile.id] = inst
            observeInstance(inst)
            inst.start()
        }
        focusedProfileID = profile.id
    }

    func stopServer(id: UUID)  { instances[id]?.stop() }
    func killServer(id: UUID)  { instances[id]?.forceKill() }

    func focusServer(_ profile: ServerProfile) {
        focusedProfileID = profile.id
        if instances[profile.id] == nil {
            let inst = ServerInstance(profile: profile)
            instances[profile.id] = inst
            observeInstance(inst)
        }
    }

    // MARK: - Profile management

    func setupProfile(name: String, path: String) {
        let profile = ServerProfile(
            name: name.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : name,
            path: path
        )
        if !profiles.contains(where: { $0.path == path }) {
            profiles.append(profile)
            let inst = ServerInstance(profile: profile)
            instances[profile.id] = inst
            observeInstance(inst)
        }
        focusedProfileID = profile.id
        saveProfiles()
    }

    func addProfile(_ p: ServerProfile) {
        guard !profiles.contains(where: { $0.path == p.path }) else { return }
        profiles.append(p)
        let inst = ServerInstance(profile: p)
        instances[p.id] = inst
        observeInstance(inst)
        saveProfiles()
    }

    func removeProfile(_ p: ServerProfile) {
        guard instances[p.id]?.status == .stopped || instances[p.id] == nil else { return }
        instanceSubs.removeValue(forKey: p.id)
        instances.removeValue(forKey: p.id)
        profiles.removeAll { $0.id == p.id }
        if focusedProfileID == p.id {
            focusedProfileID = profiles.first?.id
        }
        saveProfiles()
    }

    @discardableResult
    func removeProfile(id: UUID) -> Bool {
        guard let profile = profiles.first(where: { $0.id == id }),
              instances[id]?.status == .stopped || instances[id] == nil else { return false }
        removeProfile(profile)
        return true
    }

    func updateProfile(_ updated: ServerProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == updated.id }) {
            profiles[idx] = updated
        }
        instances[updated.id]?.profile = updated
        if focusedProfileID == updated.id {
            // trigger update for activeProfile shim
            objectWillChange.send()
        }
        saveProfiles()
    }

    func switchToProfile(_ profile: ServerProfile) {
        focusServer(profile)
    }

    func detectProfiles() {
        let basePath = profiles.first?.path ?? activeProfile.path
        let parent = (basePath as NSString).deletingLastPathComponent
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return }
        for item in items {
            let fullPath = parent + "/" + item
            let candidate = ServerProfile(name: item, path: fullPath)
            if candidate.isValid { addProfile(candidate) }
        }
    }

    func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "serverProfiles")
        }
        if let id = focusedProfileID, let profile = profiles.first(where: { $0.id == id }) {
            UserDefaults.standard.set(profile.path, forKey: "activeServerPath")
        }
    }

    // MARK: - Web API

    func startWebAPI() {
        stopWebAPI()
        guard let validPort = UInt16(exactly: webAPIPort), validPort > 0 else {
            webAPIRunning = false
            print("[WebAPI] 無効なポート番号: \(webAPIPort)")
            return
        }
        let server = HTTPServer(port: validPort)
        server.manager = self
        server.password = webAPIPassword
        do {
            try server.start()
            httpServer = server
            webAPIRunning = true
        } catch {
            webAPIRunning = false
            print("[WebAPI] 起動失敗: \(error)")
        }
    }

    func stopWebAPI() {
        httpServer?.stop()
        httpServer = nil
        webAPIRunning = false
    }

    // MARK: - Private

    private func observeInstance(_ instance: ServerInstance) {
        instanceSubs[instance.id] = instance.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

// MARK: - Uptime formatter

func formatUptime(_ t: TimeInterval) -> String {
    let h = Int(t) / 3600
    let m = (Int(t) % 3600) / 60
    let s = Int(t) % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
}
