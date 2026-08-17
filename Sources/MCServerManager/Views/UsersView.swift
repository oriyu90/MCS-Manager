import SwiftUI

struct UsersView: View {
    @EnvironmentObject var manager: ServerManager

    @State private var section:    Section  = .whitelist
    @State private var whitelist:  [WhitelistEntry]        = []
    @State private var pendingWL:  [PendingWhitelistEntry] = []
    @State private var ops:        [OpsEntry]              = []
    @State private var bans:       [BanEntry]              = []
    @State private var addName     = ""
    @State private var addPlatform = PlayerPlatform.auto
    @State private var feedback:   Feedback?
    @State private var whitelistOn = false

    struct Feedback: Identifiable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    enum Section: String, CaseIterable {
        case whitelist = "ホワイトリスト"
        case ops       = "OP"
        case bans      = "BAN"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            segmentBar
            if section != .bans { addBar }
            Divider()
            if let fb = feedback { feedbackBanner(fb) }
            listArea
        }
        .onAppear { loadAll() }
        .onChange(of: section)                      { _ in loadAll() }
        .onChange(of: manager.activeProfile.path)   { _ in loadAll() }
    }

    // MARK: - Segment Bar

    private var segmentBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $section) {
                ForEach(Section.allCases, id: \.self) { s in
                    Text(sectionLabel(s)).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button { loadAll() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help("リストを更新")

            if section == .whitelist {
                Toggle(L10n.text("有効", "Enabled"), isOn: Binding(
                    get: { whitelistOn },
                    set: { setWhitelistEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppTheme.header)
    }

    // MARK: - Add Bar

    private var addBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                TextField(L10n.text("プレイヤー名", "Player name"), text: $addName)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)
                    .onSubmit { addPlayer() }

                Button(L10n.text("追加", "Add")) { addPlayer() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .disabled(addName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, section == .whitelist ? 5 : 8)

            if section == .whitelist {
                HStack(spacing: 8) {
                    Picker("", selection: $addPlatform) {
                        ForEach(PlayerPlatform.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .help("プレイヤーの種別を選択（自動=キャッシュ参照→推測）")

                    Spacer(minLength: 8)

                    Button {
                        importCSV()
                    } label: {
                        Label("CSV", systemImage: "doc.text.fill")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("縦1列CSVからホワイトリストに一括追加（ヘッダーなし）")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            HStack(spacing: 4) {
                Image(systemName: "info.circle").font(.system(size: 9))
                Group {
                    if manager.status == .running {
                        Text("サーバー起動中 — コマンド経由で追加します")
                    } else if addPlatform == .bedrock {
                        Text("停止中・統合版 — 次回起動時にコマンドで適用されます")
                    } else {
                        Text("停止中でも追加可能 — キャッシュ / オフライン UUID を使用")
                    }
                }
                .font(.system(size: 9))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .background(AppTheme.surface)
    }

    // MARK: - Feedback Banner

    @ViewBuilder
    private func feedbackBanner(_ fb: Feedback) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: fb.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(fb.isError ? .orange : .green)
                    .font(.caption)
                Text(fb.message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { feedback = nil } label: {
                    Image(systemName: "xmark").font(.caption2).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(AppTheme.raised)
            Divider()
        }
    }

    // MARK: - List Area

    @ViewBuilder
    private var listArea: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                switch section {
                case .whitelist: whitelistRows
                case .ops:       opsRows
                case .bans:      bansRows
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder private var whitelistRows: some View {
        // Pending (Bedrock awaiting server start)
        if !pendingWL.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("保留中（次回起動時に適用）", systemImage: "clock.badge")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                ForEach(pendingWL) { entry in
                    PendingRow(entry: entry) {
                        removePending(entry)
                    }
                }
            }
            Divider().padding(.vertical, 4)
        }

        if whitelist.isEmpty && pendingWL.isEmpty {
            emptyState(L10n.text("ホワイトリストにプレイヤーはいません", "No players are on the whitelist"))
        } else {
            ForEach(whitelist) { e in
                PlayerRow(
                    name:     e.name,
                    subtitle: uuidLabel(e.uuid),
                    online:   manager.onlinePlayers.contains(e.name),
                    isBedrock: e.uuid.hasPrefix("00000000-0000-0000-"),
                    canDelete: e.name != "t329"
                ) { removeWhitelist(e) }
                onChangeToBedrock: {
                    convertToBedrock(e)
                }
            }
        }
    }

    @ViewBuilder private var opsRows: some View {
        if ops.isEmpty {
            emptyState(L10n.text("OPは設定されていません", "No operators are configured"))
        } else {
            ForEach(ops) { e in
                PlayerRow(
                    name:     e.name,
                    subtitle: "Lv.\(e.level)" + (e.bypassesPlayerLimit ? L10n.text("  · 人数制限を無視", "  · Bypasses player limit") : ""),
                    online:   manager.onlinePlayers.contains(e.name),
                    isBedrock: e.uuid.hasPrefix("00000000-0000-0000-"),
                    canDelete: e.name != "t329"
                ) { removeOp(e) }
            }
        }
    }

    @ViewBuilder private var bansRows: some View {
        if bans.isEmpty {
            emptyState(L10n.text("BANされたプレイヤーはいません", "No players are banned"))
        } else {
            ForEach(bans) { e in
                PlayerRow(
                    name:      e.displayName,
                    subtitle:  e.displayReason,
                    online:    false,
                    isBedrock: (e.uuid ?? "").hasPrefix("00000000-0000-0000-"),
                    canDelete: true,
                    removeLabel: L10n.text("BAN解除", "Pardon")
                ) { pardon(e) }
            }
        }
    }

    @ViewBuilder
    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "person.slash.fill").font(.system(size: 24)).foregroundStyle(.tertiary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Add Logic

    private func addPlayer() {
        let name = addName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard UserFiles.isValidPlayerName(name) else {
            show(L10n.text("プレイヤー名に使用できない文字が含まれています", "Player name contains invalid characters"), error: true)
            return
        }
        let path = manager.activeProfile.path

        if manager.status == .running {
            switch section {
            case .whitelist:
                let prefix = UserFiles.floodgatePrefix(in: path)
                let isBedrock = addPlatform == .bedrock || name.hasPrefix(prefix)
                if isBedrock {
                    let gameTag = UserFiles.stripFloodgatePrefix(from: name, in: path)
                    manager.sendCommand("fwhitelist add \(gameTag)")
                    show("✅ \(name) を fwhitelist add で追加しました（統合版）")
                } else {
                    manager.sendCommand("whitelist add \(name)")
                    manager.sendCommand("whitelist reload")
                    show("✅ \(name) を whitelist add で追加しました")
                }
            case .ops:
                manager.sendCommand("op \(name)")
                show("✅ \(name) を op コマンドで追加しました")
            case .bans:
                break
            }
            addName = ""
            reload(after: 1.5)
            return
        }

        // Server stopped
        switch section {
        case .whitelist:
            addWhitelistOffline(name: name, platform: addPlatform, path: path)
        case .ops:
            addOpOffline(name: name, path: path)
        case .bans:
            break
        }
        addName = ""
    }

    private func addWhitelistOffline(name: String, platform: PlayerPlatform, path: String) {
        switch platform {
        case .bedrock:
            // Always add as pending — let Floodgate handle UUID on next start
            addToPending(name: name, path: path)

        case .java:
            // Force offline Java UUID
            if whitelist.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                show("⚠️ \(name) はすでにホワイトリストにいます", error: true); return
            }
            let uuid = UserFiles.offlinePlayerUUID(name: name)
            whitelist.append(WhitelistEntry(uuid: uuid, name: name))
            UserFiles.save(whitelist, filename: "whitelist.json", to: path)
            show("✅ \(name) をホワイトリストに追加しました（Java オフライン UUID）")

        case .auto:
            // Check usercache first
            if let hit = UserFiles.lookupCache(name: name, in: path) {
                if whitelist.contains(where: { $0.uuid == hit.uuid }) {
                    show("⚠️ \(name) はすでにホワイトリストにいます", error: true); return
                }
                let isBedrock = hit.uuid.hasPrefix("00000000-0000-0000-0009-")
                whitelist.append(WhitelistEntry(uuid: hit.uuid, name: name))
                UserFiles.save(whitelist, filename: "whitelist.json", to: path)
                show("✅ \(name) を追加しました（\(isBedrock ? "統合版・" : "")キャッシュ）")
                return
            }

            // Has Floodgate prefix → Bedrock, add to pending
            let prefix = UserFiles.floodgatePrefix(in: path)
            if name.hasPrefix(prefix) {
                addToPending(name: name, path: path)
                return
            }

            // Java offline UUID
            if whitelist.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                show("⚠️ \(name) はすでにホワイトリストにいます", error: true); return
            }
            let uuid = UserFiles.offlinePlayerUUID(name: name)
            whitelist.append(WhitelistEntry(uuid: uuid, name: name))
            UserFiles.save(whitelist, filename: "whitelist.json", to: path)
            show("✅ \(name) をホワイトリストに追加しました（Java UUID）\n💡 統合版プレイヤーの場合は種別を「統合版」にして追加し直してください")
        }
    }

    private func addToPending(name: String, path: String) {
        let prefix = UserFiles.floodgatePrefix(in: path)
        let beName   = name.hasPrefix(prefix) ? name : prefix + name
        let gameTag  = UserFiles.stripFloodgatePrefix(from: beName, in: path)
        if pendingWL.contains(where: { $0.name.lowercased() == beName.lowercased() }) {
            show("⚠️ \(beName) はすでに保留リストにあります", error: true); return
        }
        let entry = PendingWhitelistEntry(
            name: beName,
            command: "fwhitelist add \(gameTag)",
            addedAt: Date()
        )
        pendingWL.append(entry)
        UserFiles.save(pendingWL, filename: "pending_whitelist.json", to: path)
        show("✅ \(beName) を保留リストに追加しました\n次回サーバー起動時に自動で fwhitelist add が実行されます")
    }

    private func addOpOffline(name: String, path: String) {
        guard let resolved = UserFiles.resolvePlayer(name: name, in: path) else {
            show("⚠️ 「\(name)」は統合版プレイヤーで未接続のため UUID を解決できません\nサーバー起動中に追加してください", error: true)
            return
        }
        if ops.contains(where: { $0.uuid == resolved.uuid }) {
            show("⚠️ \(name) はすでに OP です", error: true); return
        }
        ops.append(OpsEntry(uuid: resolved.uuid, name: name, level: 4, bypassesPlayerLimit: false))
        UserFiles.save(ops, filename: "ops.json", to: path)
        show("✅ \(name) を OP に追加しました（\(resolved.note)）")
    }

    // Convert a Java-UUID entry to Bedrock pending
    private func convertToBedrock(_ entry: WhitelistEntry) {
        let path = manager.activeProfile.path
        // Remove existing Java entry
        whitelist.removeAll { $0.uuid == entry.uuid }
        UserFiles.save(whitelist, filename: "whitelist.json", to: path)

        if manager.status == .running {
            let gameTag = UserFiles.stripFloodgatePrefix(from: entry.name, in: path)
            manager.sendCommand("fwhitelist add \(gameTag)")
            show("✅ \(entry.name) を統合版として fwhitelist add しました")
            reload(after: 1.5)
        } else {
            addToPending(name: entry.name, path: path)
        }
    }

    // MARK: - CSV Import

    private func importCSV() {
        FilePanelPresenter.chooseCSV { url in
            guard let url else { return }
            processCSV(url: url)
        }
    }

    private func processCSV(url: URL) {
        guard let raw = (try? String(contentsOf: url, encoding: .utf8))
                     ?? (try? String(contentsOf: url, encoding: .shiftJIS)) else {
            show("❌ ファイルを読み込めませんでした", error: true); return
        }

        let names: [String] = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r",   with: "\n")
            .components(separatedBy: "\n")
            .map { $0
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\"'"))
            }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !names.isEmpty else {
            show("⚠️ 有効なプレイヤー名が見つかりませんでした", error: true); return
        }

        let path = manager.activeProfile.path

        if manager.status == .running {
            if addPlatform == .bedrock {
                for name in names {
                    let gameTag = UserFiles.stripFloodgatePrefix(from: name, in: path)
                    manager.sendCommand("fwhitelist add \(gameTag)")
                }
                show("✅ \(names.count)件の fwhitelist add を送信しました（統合版）")
            } else {
                for name in names { manager.sendCommand("whitelist add \(name)") }
                manager.sendCommand("whitelist reload")
                show("✅ \(names.count)件の whitelist add を送信しました")
            }
            reload(after: 2.0)
            return
        }

        // Offline: resolve each
        let cache: [UserCacheEntry] = UserFiles.load("usercache.json", from: path)
        let bdPrefix = UserFiles.floodgatePrefix(in: path)

        var added:   [String] = []
        var skipped: [String] = []
        var pending_added: [String] = []

        for name in names {
            // Existing check
            let alreadyInWL = whitelist.contains { $0.name.lowercased() == name.lowercased() }
            let alreadyInPending = pendingWL.contains { $0.name.lowercased() == name.lowercased()
                || $0.name.lowercased() == (bdPrefix + name).lowercased() }

            if alreadyInWL || alreadyInPending { skipped.append(name); continue }

            // Resolve
            if let hit = cache.first(where: { $0.name.lowercased() == name.lowercased() }) {
                if whitelist.contains(where: { $0.uuid == hit.uuid }) {
                    skipped.append(name); continue
                }
                whitelist.append(WhitelistEntry(uuid: hit.uuid, name: name))
                added.append(name)
            } else if name.hasPrefix(bdPrefix) {
                // Has prefix → Bedrock, add to pending
                let gameTag = UserFiles.stripFloodgatePrefix(from: name, in: path)
                let entry = PendingWhitelistEntry(
                    name: name,
                    command: "fwhitelist add \(gameTag)",
                    addedAt: Date()
                )
                pendingWL.append(entry)
                pending_added.append(name)
            } else if addPlatform == .bedrock {
                // CSV imported with platform=Bedrock → all go to pending with prefix
                let beName = bdPrefix + name
                let entry = PendingWhitelistEntry(
                    name: beName,
                    command: "fwhitelist add \(name)",
                    addedAt: Date()
                )
                pendingWL.append(entry)
                pending_added.append(beName)
            } else {
                // Java offline UUID
                let uuid = UserFiles.offlinePlayerUUID(name: name)
                if whitelist.contains(where: { $0.uuid == uuid }) {
                    skipped.append(name); continue
                }
                whitelist.append(WhitelistEntry(uuid: uuid, name: name))
                added.append(name)
            }
        }

        if !added.isEmpty {
            UserFiles.save(whitelist, filename: "whitelist.json", to: path)
        }
        if !pending_added.isEmpty {
            UserFiles.save(pendingWL, filename: "pending_whitelist.json", to: path)
        }

        var parts: [String] = []
        if !added.isEmpty        { parts.append("✅ \(added.count)件追加（JSON）") }
        if !pending_added.isEmpty { parts.append("⏳ \(pending_added.count)件保留（統合版・次回起動時適用）") }
        if !skipped.isEmpty      { parts.append("⏭ \(skipped.count)件スキップ（既存）") }
        show(parts.joined(separator: "\n"), error: false)
    }

    // MARK: - Remove / Pardon

    private func removeWhitelist(_ entry: WhitelistEntry) {
        if manager.status == .running {
            manager.sendCommand("whitelist remove \(entry.name)")
            show("🗑 whitelist remove \(entry.name) を送信しました")
            reload(after: 1.5)
        } else {
            whitelist.removeAll { $0.uuid == entry.uuid }
            UserFiles.save(whitelist, filename: "whitelist.json", to: manager.activeProfile.path)
            show("🗑 \(entry.name) をホワイトリストから削除しました")
        }
    }

    private func removePending(_ entry: PendingWhitelistEntry) {
        pendingWL.removeAll { $0.id == entry.id }
        UserFiles.save(pendingWL, filename: "pending_whitelist.json", to: manager.activeProfile.path)
        show("🗑 \(entry.name) の保留を取り消しました")
    }

    private func removeOp(_ entry: OpsEntry) {
        if manager.status == .running {
            manager.sendCommand("deop \(entry.name)")
            show("🗑 deop \(entry.name) を送信しました")
            reload(after: 1.5)
        } else {
            ops.removeAll { $0.uuid == entry.uuid }
            UserFiles.save(ops, filename: "ops.json", to: manager.activeProfile.path)
            show("🗑 \(entry.name) の OP を解除しました")
        }
    }

    private func pardon(_ entry: BanEntry) {
        if manager.status == .running, let name = entry.name {
            manager.sendCommand("pardon \(name)")
            show("🗑 pardon \(name) を送信しました")
            reload(after: 1.5)
        } else {
            bans.removeAll { $0.id == entry.id }
            UserFiles.save(bans, filename: "banned-players.json", to: manager.activeProfile.path)
            show("🗑 \(entry.displayName) の BAN を解除しました")
        }
    }

    // MARK: - Helpers

    private func loadAll() {
        let path = manager.activeProfile.path
        whitelistOn = manager.activeProfile.whitelistEnabled
        switch section {
        case .whitelist:
            whitelist = (UserFiles.load("whitelist.json", from: path) as [WhitelistEntry])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            pendingWL = UserFiles.load("pending_whitelist.json", from: path)
        case .ops:
            ops = (UserFiles.load("ops.json", from: path) as [OpsEntry])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .bans:
            bans = UserFiles.load("banned-players.json", from: path)
        }
    }

    private func setWhitelistEnabled(_ enabled: Bool) {
        guard manager.activeProfile.writeProperties(["white-list": enabled ? "true" : "false"]) else {
            show(L10n.text("server.properties の更新に失敗しました", "Could not update server.properties"), error: true)
            return
        }
        whitelistOn = enabled
        if manager.status == .running { manager.sendCommand("whitelist \(enabled ? "on" : "off")") }
        show(enabled ? L10n.text("ホワイトリストを有効にしました", "Whitelist enabled") : L10n.text("ホワイトリストを無効にしました", "Whitelist disabled"))
    }

    private func reload(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { loadAll() }
    }

    private func show(_ msg: String, error: Bool = false) {
        feedback = Feedback(message: msg, isError: error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if self.feedback?.message == msg { self.feedback = nil }
        }
    }

    private func sectionLabel(_ s: Section) -> String {
        switch s {
        case .whitelist: return L10n.text("ホワイトリスト (\(whitelist.count)\(pendingWL.isEmpty ? "" : "+\(pendingWL.count)保留"))", "Whitelist (\(whitelist.count)\(pendingWL.isEmpty ? "" : "+\(pendingWL.count) pending"))")
        case .ops:       return "OP (\(ops.count))"
        case .bans:      return "BAN (\(bans.count))"
        }
    }

    private func uuidLabel(_ uuid: String) -> String {
        if uuid.hasPrefix("00000000-0000-0000-") {
            return L10n.text("統合版  ", "Bedrock  ") + String(uuid.suffix(12))
        }
        return "Java  " + String(uuid.prefix(8)) + "..."
    }
}

// MARK: - Pending Row

private struct PendingRow: View {
    let entry: PendingWhitelistEntry
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.15)).frame(width: 34, height: 34)
                Image(systemName: "clock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .semibold))
                    Label("統合版・保留", systemImage: "puzzlepiece.extension.fill")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                        .foregroundStyle(.orange)
                }
                Text("次回サーバー起動時に適用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onCancel()
            } label: {
                Text("取消")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(AppTheme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.2)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.2)))
    }
}

// MARK: - PlayerRow

private struct PlayerRow: View {
    let name: String
    let subtitle: String
    let online: Bool
    let isBedrock: Bool
    let canDelete: Bool
    var removeLabel: String = L10n.text("削除", "Remove")
    let onRemove: () -> Void
    var onChangeToBedrock: (() -> Void)? = nil

    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if showConfirm { confirmBar }
        }
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(showConfirm ? Color.red.opacity(0.08) : AppTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(showConfirm ? Color.red.opacity(0.25) : Color.secondary.opacity(0.1)))
        .animation(.easeInOut(duration: 0.12), value: showConfirm)
    }

    // Break into sub-views so the type-checker doesn't time out
    private var mainRow: some View {
        HStack(spacing: 10) {
            avatarView
            infoView
            Spacer()
            trailingButtons
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(avatarColor(for: name))
                .frame(width: 34, height: 34)
            Text(String((isBedrock ? name.dropFirst() : name.prefix(1)).prefix(1)).uppercased())
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var infoView: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                platformBadge
                if online {
                    Text("● オンライン")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.green)
                }
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var platformBadge: some View {
        Group {
            if isBedrock {
                Label("統合版", systemImage: "puzzlepiece.extension.fill")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.teal.opacity(0.15)))
                    .foregroundStyle(.teal)
            } else {
                Label("Java", systemImage: "cup.and.saucer.fill")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var trailingButtons: some View {
        if !isBedrock, let changeToBedrock = onChangeToBedrock {
            Button {
                changeToBedrock()
            } label: {
                Label("統合版に変更", systemImage: "puzzlepiece.extension")
                    .font(.system(size: 9))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.teal.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.teal.opacity(0.2)))
                    .foregroundStyle(.teal)
            }
            .buttonStyle(.plain)
            .help("統合版プレイヤーとして再登録します")
        }

        if canDelete {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showConfirm.toggle() }
            } label: {
                Text(showConfirm ? "▲" : removeLabel)
                    .font(.caption)
                    .foregroundStyle(showConfirm ? Color.secondary : Color.red)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(showConfirm ? Color.secondary.opacity(0.06) : Color.red.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(showConfirm ? Color.secondary.opacity(0.2) : Color.red.opacity(0.2)))
            }
            .buttonStyle(.plain)
        } else {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("管理者アカウントは変更できません")
        }
    }

    // Inline confirm — avoids system alert which closes the MenuBarExtra window
    private var confirmBar: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 10)
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
                Text(L10n.text("\(name)を\(removeLabel)しますか？", "\(removeLabel) \(name)?"))
                    .font(.caption)
                Spacer()
                Button("キャンセル") {
                    withAnimation(.easeInOut(duration: 0.12)) { showConfirm = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                Button(removeLabel) {
                    showConfirm = false; onRemove()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(.red)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.red.opacity(0.04))
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func avatarColor(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .mint, .cyan]
        return palette[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]
    }
}
