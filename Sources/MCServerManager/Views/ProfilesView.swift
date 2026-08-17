import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject var manager: ServerManager

    @State private var showingAddForm  = false
    @State private var deleteTargetID: UUID?   // inline confirm instead of .alert()
    @State private var newName = ""
    @State private var newPath = ""
    @State private var pathError: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(spacing: 6) {
                    if showingAddForm {
                        InlineAddForm(name: $newName, path: $newPath, error: $pathError) {
                            let p = ServerProfile(
                                name: newName.isEmpty
                                    ? URL(fileURLWithPath: newPath).lastPathComponent
                                    : newName,
                                path: newPath
                            )
                            if p.isValid {
                                manager.addProfile(p)
                                withAnimation { showingAddForm = false }
                            } else {
                                pathError = L10n.text("server.propertiesが見つかりません", "server.properties was not found")
                            }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if manager.profiles.isEmpty && !showingAddForm {
                        emptyState
                    } else {
                        ForEach(manager.profiles) { profile in
                            let inst      = manager.instances[profile.id]
                            let isFocused = profile.id == manager.focusedProfileID
                            let isPending = deleteTargetID == profile.id

                            ProfileRow(
                                profile:     profile,
                                status:      inst?.status ?? .stopped,
                                playerCount: inst?.onlinePlayers.count ?? 0,
                                isFocused:   isFocused,
                                isDeletePending: isPending
                            ) {
                                manager.focusServer(profile)
                            } onStart: {
                                manager.startServer(profile: profile)
                            } onStop: {
                                manager.stopServer(id: profile.id)
                            } onDelete: {
                                // Show inline confirmation instead of system alert
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    deleteTargetID = profile.id
                                }
                            } onDeleteConfirm: {
                                manager.removeProfile(profile)
                                deleteTargetID = nil
                            } onDeleteCancel: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    deleteTargetID = nil
                                }
                            } onToggleAutoStart: {
                                var updated = profile
                                updated.autoStartServer.toggle()
                                manager.updateProfile(updated)
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Text("サーバープロファイル")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                manager.detectProfiles()
            } label: {
                Label("自動検出", systemImage: "magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            if showingAddForm {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showingAddForm = false }
                } label: {
                    Label("キャンセル", systemImage: "xmark").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else {
                Button {
                    newName = ""; newPath = ""; pathError = nil
                    withAnimation(.easeInOut(duration: 0.2)) { showingAddForm = true }
                } label: {
                    Label("追加", systemImage: "plus").font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppTheme.header)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("プロファイルがありません")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("「自動検出」または「追加」で登録")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - Inline Add Form

private struct InlineAddForm: View {
    @Binding var name: String
    @Binding var path: String
    @Binding var error: String?
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("サーバーを追加")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(path.isEmpty ? L10n.text("フォルダを選択…", "Choose a folder…") : path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(path.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(AppTheme.input))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(error != nil ? Color.red.opacity(0.6) : Color.secondary.opacity(0.25), lineWidth: 1))

                Button("選択...") {
                    FilePanelPresenter.chooseServerFolder { url in
                        if let url { path = url.path }
                        error = nil
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }

            if let err = error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                TextField("表示名（省略可）", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                Button("追加") { onAdd() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(path.isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Profile Row

private struct ProfileRow: View {
    let profile: ServerProfile
    let status: ServerStatus
    let playerCount: Int
    let isFocused: Bool
    let isDeletePending: Bool
    let onFocus: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onDelete: () -> Void
    let onDeleteConfirm: () -> Void
    let onDeleteCancel: () -> Void
    let onToggleAutoStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Main info row
            HStack(spacing: 10) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(profile.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)

                        Text(status.label)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(status.color.opacity(0.15)))
                            .foregroundStyle(status.color)

                        if isFocused {
                            Text("表示中")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                .foregroundStyle(Color.accentColor)
                        }

                        if status == .running {
                            Text(L10n.text("\(playerCount)人", "\(playerCount) online"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(profile.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        if let jar = profile.jarName {
                            Label(jar.replacingOccurrences(of: ".jar", with: ""), systemImage: "puzzlepiece.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Label(":\(profile.serverPort)", systemImage: "network")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Control buttons
                HStack(spacing: 4) {
                    if !isFocused {
                        Button("表示") { onFocus() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("ダッシュボード・コンソールに表示")
                    }

                    if status.canStart {
                        Button { onStart() } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("起動")
                    } else if status.canStop {
                        Button { onStop() } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("停止")
                    }

                    if status == .stopped && !isDeletePending {
                        Button { onDelete() } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .help("削除")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // Inline delete confirmation (replaces system alert which breaks MenuBarExtra)
            if isDeletePending {
                Divider().padding(.horizontal, 10)

                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)

                    Text(L10n.text("「\(profile.name)」を一覧から削除しますか？", "Remove “\(profile.name)” from the list?"))
                        .font(.caption)
                        .foregroundStyle(.primary)

                    Spacer()

                    Button("キャンセル") { onDeleteCancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                    Button("削除") { onDeleteConfirm() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .tint(.red)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.05))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Auto-start toggle
            Divider().padding(.horizontal, 10)

            HStack {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(profile.autoStartServer ? .green : .secondary)

                Text("アプリ起動時にこのサーバーを自動起動")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle("", isOn: Binding(
                    get: { profile.autoStartServer },
                    set: { _ in onToggleAutoStart() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(profile.autoStartServer ? Color.green.opacity(0.04) : Color.clear)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDeletePending
                    ? Color.red.opacity(0.04)
                    : isFocused
                        ? Color.accentColor.opacity(0.05)
                        : AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDeletePending
                    ? Color.red.opacity(0.3)
                    : isFocused
                        ? Color.accentColor.opacity(0.2)
                        : AppTheme.border)
        )
        .animation(.easeInOut(duration: 0.15), value: isDeletePending)
    }
}
