import SwiftUI

struct SetupView: View {
    @EnvironmentObject var manager: ServerManager

    @State private var selectedPath = ""
    @State private var profileName  = ""
    @State private var validState: ValidState = .none

    enum ValidState {
        case none, valid, invalid(String)
        var isValid: Bool { if case .valid = self { return true }; return false }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Icon + Title
            VStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(AppTheme.accent)

                Text("サーバーフォルダを設定")
                    .font(.system(size: 16, weight: .semibold))

                Text(L10n.text("Paper / Spigot / Purpur / Vanillaのサーバーフォルダを選択してください\n（server.propertiesが含まれているフォルダ）", "Select a Paper, Spigot, Purpur, or vanilla server folder\n(the folder containing server.properties)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(.top, 32)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                // Folder picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("サーバーフォルダ")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Text(selectedPath.isEmpty ? L10n.text("未選択", "Not selected") : selectedPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(selectedPath.isEmpty ? .tertiary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(AppTheme.input)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )

                        Button("選択...") { pickFolder() }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                    }
                }

                // Validation indicator
                if !selectedPath.isEmpty {
                    HStack(spacing: 6) {
                        switch validState {
                        case .valid:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("有効なサーバーフォルダです").foregroundStyle(.green)
                        case .invalid(let msg):
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text(msg).foregroundStyle(.red)
                        case .none:
                            EmptyView()
                        }
                    }
                    .font(.caption)
                }

                // Profile name
                VStack(alignment: .leading, spacing: 6) {
                    Text("表示名（省略可）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(L10n.text("例：メインサーバー", "Example: Main Server"), text: $profileName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                Divider()

                // Save button
                Button {
                    manager.setupProfile(name: profileName, path: selectedPath)
                } label: {
                    Label("このフォルダを登録して開始", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!validState.isValid)

                // Or: if other valid profiles already exist
                if manager.profiles.contains(where: { $0.isValid }) {
                    Button {
                        if let valid = manager.profiles.first(where: { $0.isValid }) {
                            manager.activeProfile = valid
                        }
                    } label: {
                        Text("既存のプロファイルを使う")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            .padding(20)
            .background(AppTheme.surface)

            Spacer(minLength: 0)
        }
        .background(AppTheme.background)
    }

    private func pickFolder() {
        FilePanelPresenter.chooseServerFolder { url in
            guard let url else { return }
            selectedPath = url.path
            validate(path: selectedPath)
        }
    }

    private func validate(path: String) {
        let fm = FileManager.default
        let hasProps = fm.fileExists(atPath: path + "/server.properties")
        let hasJar   = (try? fm.contentsOfDirectory(atPath: path))?.contains(where: {
            $0.hasSuffix(".jar") && ($0.hasPrefix("paper") || $0.hasPrefix("spigot") || $0.hasPrefix("purpur") || $0 == "server.jar")
        }) ?? false

        if hasProps && hasJar {
            validState = .valid
        } else if hasProps {
            validState = .invalid(L10n.text("JAR ファイルが見つかりません (Paper / Spigot / Purpur / server.jar)", "No supported JAR found (Paper / Spigot / Purpur / server.jar)"))
        } else {
            validState = .invalid(L10n.text("server.propertiesが見つかりません", "server.properties was not found"))
        }
    }
}
