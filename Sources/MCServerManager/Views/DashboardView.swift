import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var manager: ServerManager
    @State private var showQuickCommands = false
    @State private var broadcastText = ""
    @State private var showBroadcast = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                // Status Card
                statusCard

                // Action Buttons
                actionButtons

                // Players Card
                if !manager.onlinePlayers.isEmpty || manager.status == .running {
                    playersCard
                }

                // Quick Commands
                quickCommands

                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(manager.status.color.opacity(0.22))
                    .frame(width: 44, height: 44)
                Circle()
                    .stroke(manager.status.color.opacity(0.65), lineWidth: 1.5)
                    .frame(width: 44, height: 44)
                Circle()
                    .fill(manager.status.color)
                    .frame(width: 12, height: 12)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(manager.activeProfile.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(manager.status.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(manager.status.color)

                    if manager.status == .running, manager.uptime > 0 {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(formatUptime(manager.uptime))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if let jar = manager.activeProfile.jarName {
                    Text(jar)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("\(manager.onlinePlayers.count)/\(manager.activeProfile.maxPlayers)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }

                Text("port \(manager.activeProfile.serverPort)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .appPanel(accent: manager.status.color)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 8) {
            ActionButton(
                label: L10n.text("起動", "Start"),
                icon: "play.fill",
                color: .green,
                disabled: !manager.status.canStart
            ) { manager.start() }

            ActionButton(
                label: L10n.text("停止", "Stop"),
                icon: "stop.fill",
                color: .orange,
                disabled: !manager.status.canStop
            ) { manager.stop() }

            ActionButton(
                label: L10n.text("再起動", "Restart"),
                icon: "arrow.clockwise",
                color: .blue,
                disabled: !manager.status.canStop
            ) { manager.restart() }

            ActionButton(
                label: L10n.text("強制終了", "Force quit"),
                icon: "xmark.circle.fill",
                color: .red,
                disabled: !manager.status.isActive
            ) { manager.forceKill() }
        }
    }

    // MARK: - Players Card

    private var playersCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.text("オンラインプレイヤー", "Online players"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L10n.text("\(manager.onlinePlayers.count)人", "\(manager.onlinePlayers.count) online"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if manager.onlinePlayers.isEmpty {
                Text(L10n.text("プレイヤーなし", "No players"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 4) {
                    ForEach(manager.onlinePlayers, id: \.self) { name in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(.green)
                                .frame(width: 5, height: 5)
                            Text(name)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.08)))
                    }
                }
            }
        }
        .padding(12)
        .appPanel(accent: .green)
    }

    // MARK: - Quick Commands

    private var quickCommands: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showQuickCommands.toggle() }
            } label: {
                HStack {
                    Image(systemName: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.text("クイックコマンド", "Quick commands"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: showQuickCommands ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if showQuickCommands {
                VStack(spacing: 6) {
                    // Broadcast row
                    HStack(spacing: 6) {
                        TextField(L10n.text("ブロードキャスト本文…", "Broadcast message…"), text: $broadcastText)
                            .font(.system(size: 11))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(AppTheme.input))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                            .onSubmit { sendBroadcast() }

                        Button(L10n.text("送信", "Send")) { sendBroadcast() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(broadcastText.isEmpty || manager.status != .running)
                    }

                    // Command buttons
                    HStack(spacing: 6) {
                        QuickCmdButton(label: "save-all",   icon: "square.and.arrow.down.fill") {
                            manager.sendCommand("save-all")
                        }
                        QuickCmdButton(label: "reload",     icon: "arrow.clockwise") {
                            manager.sendCommand("reload confirm")
                        }
                        QuickCmdButton(label: "whitelist",  icon: "list.bullet") {
                            manager.sendCommand("whitelist list")
                        }
                        QuickCmdButton(label: "tps",        icon: "chart.line.uptrend.xyaxis") {
                            manager.sendCommand("tps")
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .appPanel(accent: AppTheme.cyan)
    }

    private func sendBroadcast() {
        guard !broadcastText.isEmpty, manager.status == .running else { return }
        manager.sendCommand("say \(broadcastText)")
        broadcastText = ""
    }
}

// MARK: - Subviews

private struct ActionButton: View {
    let label: String
    let icon: String
    let color: Color
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(disabled ? AppTheme.raised.opacity(0.55) : color.opacity(0.20))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(disabled ? AppTheme.border : color.opacity(0.65), lineWidth: 1)
            )
            .foregroundStyle(disabled ? Color.secondary : color)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct QuickCmdButton: View {
    let label: String
    let icon: String
    let action: () -> Void

    @EnvironmentObject var manager: ServerManager

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(AppTheme.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.border))
            .foregroundStyle(manager.status == .running ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(manager.status != .running)
    }
}
