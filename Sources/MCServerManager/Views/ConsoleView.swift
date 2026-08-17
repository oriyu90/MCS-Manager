import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject var manager: ServerManager

    @State private var commandInput   = ""
    @State private var commandHistory: [String] = []
    @State private var historyIndex   = -1
    @State private var filterText     = ""
    @State private var autoScroll     = true
    @State private var showOnlyErrors = false

    private var filteredLogs: [LogEntry] {
        var entries = manager.logs
        if showOnlyErrors {
            entries = entries.filter { $0.level == .error || $0.level == .warn }
        }
        if !filterText.isEmpty {
            let q = filterText.lowercased()
            entries = entries.filter { $0.raw.lowercased().contains(q) }
        }
        return entries
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            logArea
            Divider()
            commandBar
        }
    }

    // MARK: - Filter Bar (2 rows to avoid overflow at 500pt)

    private var filterBar: some View {
        VStack(spacing: 0) {
            // Row 1: search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(L10n.text("ログを検索…", "Search logs…"), text: $filterText)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)

                if !filterText.isEmpty {
                    Button { filterText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            // Row 2: toggles + clear
            HStack(spacing: 10) {
                Toggle(isOn: $showOnlyErrors) {
                    Label("WARN/ERR のみ", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                }
                .toggleStyle(.checkbox)
                .controlSize(.mini)

                Toggle(isOn: $autoScroll) {
                    Label("自動スクロール", systemImage: "arrow.down.to.line")
                        .font(.caption2)
                }
                .toggleStyle(.checkbox)
                .controlSize(.mini)

                Spacer()

                Button {
                    manager.clearLogs()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("ログをクリア")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .background(AppTheme.header)
    }

    // MARK: - Log Area

    private var logArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredLogs) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Color.clear.frame(height: 1).id("bottom")
            }
            .font(.system(size: 11, design: .monospaced))
            .background(AppTheme.input)
            .onChange(of: manager.logs.count) { _ in
                if autoScroll {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Command Bar

    private var commandBar: some View {
        HStack(spacing: 8) {
            Text(">")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(manager.status == .running ? .green : .secondary)

            TextField(
                manager.status == .running
                    ? L10n.text("コマンドを入力…（Enterで送信）", "Enter a command… (press Enter to send)")
                    : L10n.text("サーバーは停止中です", "Server is stopped"),
                text: $commandInput
            )
            .font(.system(size: 12, design: .monospaced))
            .textFieldStyle(.plain)
            .disabled(manager.status != .running)
            .onSubmit { submitCommand() }

            if manager.status == .running && !commandInput.isEmpty {
                Button(action: submitCommand) {
                    Image(systemName: "return")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppTheme.header)
    }

    private func submitCommand() {
        let cmd = commandInput.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, manager.status == .running else { return }
        manager.sendCommand(cmd)
        commandHistory.insert(cmd, at: 0)
        if commandHistory.count > 50 { commandHistory.removeLast() }
        commandInput = ""
        historyIndex = -1
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if !entry.time.isEmpty {
                Text(entry.time)
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
            }

            if entry.level != .other && entry.level != .info {
                Text(entry.level.badge)
                    .foregroundStyle(entry.level.color)
                    .padding(.horizontal, 3)
                    .background(entry.level.badgeColor, in: RoundedRectangle(cornerRadius: 2))
                    .frame(width: 34)
            } else {
                Spacer().frame(width: 34)
            }

            Text(entry.message.isEmpty ? entry.raw : entry.message)
                .foregroundStyle(entry.level.color)
                .textSelection(.enabled)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 2)
    }
}
