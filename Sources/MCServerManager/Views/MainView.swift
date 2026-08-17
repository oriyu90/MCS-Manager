import SwiftUI

enum Tab: String, CaseIterable {
    case dashboard, console, users, servers, settings

    var title: String {
        switch self {
        case .dashboard: return L10n.text("ダッシュボード", "Dashboard")
        case .console: return L10n.text("コンソール", "Console")
        case .users: return L10n.text("ユーザー", "Users")
        case .servers: return L10n.text("サーバー", "Servers")
        case .settings: return L10n.text("設定", "Settings")
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
        case .console:   return "terminal.fill"
        case .users:     return "person.2.fill"
        case .servers:   return "server.rack"
        case .settings:  return "gearshape.fill"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var manager: ServerManager
    @State private var selectedTab: Tab = .dashboard

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if manager.hasValidProfile {
                // Server selector (shows when multiple profiles exist)
                if manager.profiles.count > 1 {
                    serverSelector
                    Divider()
                }

                tabBar
                Divider()

                Group {
                    switch selectedTab {
                    case .dashboard: DashboardView()
                    case .console:   ConsoleView()
                    case .users:     UsersView()
                    case .servers:   ProfilesView()
                    case .settings:  SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environmentObject(manager)
            } else {
                SetupView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environmentObject(manager)
            }
        }
        .background(AppTheme.background)
        .onAppear {
            if !manager.activeProfile.isValid,
               let valid = manager.profiles.first(where: { $0.isValid }) {
                manager.focusServer(valid)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube.fill")
                .foregroundStyle(manager.status.color)
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 1) {
                Text("MC Server Manager")
                    .font(.system(size: 13, weight: .semibold))
                Text("v1.0.0")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.muted)
            }

            Spacer()

            // Web API indicator
            if manager.webAPIRunning {
                HStack(spacing: 3) {
                    Circle().fill(.green).frame(width: 5, height: 5)
                    Text("API")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.green.opacity(0.12)))
                .overlay(Capsule().stroke(Color.green.opacity(0.35)))
                .help(L10n.text("Web API稼働中（ポート \(manager.webAPIPort)）", "Web API running (port \(manager.webAPIPort))"))
            }

            Picker("Language", selection: $manager.appLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .frame(width: 88)

            Button {
                manager.quitApplication()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .disabled(manager.isQuitting)
            .help(L10n.text("終了（サーバーを安全に停止）", "Quit (safely stop servers)"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(AppTheme.header)
    }

    // MARK: - Server Selector

    private var serverSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(manager.profiles) { profile in
                    let inst = manager.instances[profile.id]
                    let isFocused = profile.id == manager.focusedProfileID
                    let status = inst?.status ?? .stopped

                    Button {
                        manager.focusServer(profile)
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(status.color)
                                .frame(width: 6, height: 6)
                            Text(profile.name)
                                .font(.system(size: 10, weight: isFocused ? .semibold : .regular))
                                .lineLimit(1)
                            if let inst, inst.status == .running {
                                Text(L10n.text("·\(inst.onlinePlayers.count)人", "·\(inst.onlinePlayers.count) online"))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isFocused ? AppTheme.accent.opacity(0.22) : AppTheme.raised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isFocused ? AppTheme.accent.opacity(0.75) : AppTheme.border, lineWidth: 1)
                        )
                        .foregroundStyle(isFocused ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(AppTheme.header)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10))
                        Text(tab.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.vertical, 7)
                    .frame(minHeight: 40)
                    .frame(maxWidth: .infinity)
                    .background(selectedTab == tab ? AppTheme.accent.opacity(0.20) : Color.clear)
                    .foregroundStyle(selectedTab == tab ? Color.white : AppTheme.muted)
                    .overlay(alignment: .bottom) {
                        if selectedTab == tab {
                            Rectangle().fill(AppTheme.accent).frame(height: 2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .background(AppTheme.header)
    }
}
