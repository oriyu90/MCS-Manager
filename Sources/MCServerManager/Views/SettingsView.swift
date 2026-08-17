import SwiftUI
import Darwin

struct SettingsView: View {
    @EnvironmentObject var manager: ServerManager

    @State private var localIP = L10n.text("取得中…", "Detecting…")
    @State private var showPassword = false
    @State private var portText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                languageSection
                webAPISection
                infoSection
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .onAppear {
            fetchLocalIP()
            portText = String(manager.webAPIPort)
        }
    }

    private var languageSection: some View {
        HStack {
            Label(L10n.text("表示言語", "Language"), systemImage: "character.bubble")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Picker("", selection: $manager.appLanguage) {
                ForEach(AppLanguage.allCases) { language in Text(language.displayName).tag(language) }
            }
            .labelsHidden()
            .frame(width: 130)
        }
        .padding(12)
        .appPanel(accent: AppTheme.cyan)
    }

    // MARK: - Web API Section

    private var webAPISection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "globe.asia.australia.fill")
                    .foregroundStyle(.blue)
                Text(L10n.text("Webページ / API（外部管理）", "Web dashboard / API"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                // Status indicator
                if manager.webAPIRunning {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text(L10n.text("稼働中", "Running"))
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                } else {
                    HStack(spacing: 4) {
                        Circle().fill(.secondary).frame(width: 6, height: 6)
                        Text(L10n.text("停止", "Stopped"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // Enable toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Webページと API を有効にする", "Enable web dashboard and API"))
                        .font(.system(size: 12))
                    Text(L10n.text("Webページや外部クライアントからサーバーを管理できます", "Manage servers from the web dashboard or an external client"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $manager.webAPIEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if manager.webAPIEnabled {
                // Port
                HStack {
                    Text(L10n.text("ポート番号", "Port"))
                        .font(.system(size: 12))
                    Spacer()
                    TextField("25580", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 70)
                        .onChange(of: portText) { v in
                            if let p = Int(v), p > 0, p < 65536 {
                                manager.webAPIPort = p
                            }
                        }
                    Text("/tcp")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Password
                HStack {
                    Text(L10n.text("パスワード", "Password"))
                        .font(.system(size: 12))
                    Spacer()
                    if showPassword {
                        TextField(L10n.text("未設定（認証なし）", "Not set (no authentication)"), text: $manager.webAPIPassword)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(width: 160)
                    } else {
                        SecureField(L10n.text("未設定（認証なし）", "Not set (no authentication)"), text: $manager.webAPIPassword)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(width: 160)
                    }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Restart button
                HStack {
                    Spacer()
                    Button {
                        manager.stopWebAPI()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            manager.startWebAPI()
                        }
                    } label: {
                        Label("設定を適用・再起動", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider()

                // Connection info
                VStack(alignment: .leading, spacing: 6) {
                    Text("接続先 URL")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Group {
                        connectionURL(label: L10n.text("同じネットワーク", "Local network"),
                                      url: "http://\(localIP):\(manager.webAPIPort)")
                        connectionURL(label: L10n.text("このMacのみ", "This Mac only"),
                                      url: "http://127.0.0.1:\(manager.webAPIPort)")
                    }

                    if !manager.webAPIPassword.isEmpty {
                        Text("Authorization: Bearer <パスワード> ヘッダーが必要です")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                    } else {
                        Text("⚠️ パスワード未設定: 同一ネットワーク内の誰でも操作できます")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .padding(.top, 2)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.15)))

                // iPad / iOS note (inside the webAPIEnabled block)
                ipadNote
            }
        }
        .padding(12)
        .appPanel(accent: AppTheme.accent)
    }

    private var ipadNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "ipad.and.iphone")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("iPad / iPhone から接続する場合")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.blue)
            }
            Text("HTTPS サイトから HTTP API への接続はブラウザがブロックします（Mixed Content）。\nSafari で直接 URL を開いてください — アプリ内管理ページが表示されます。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
            HStack(spacing: 6) {
                Text("http://\(localIP):\(manager.webAPIPort)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.blue)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("http://\(localIP):\(manager.webAPIPort)", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.2)))
    }

    private func connectionURL(label: String, url: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("コピー")
        }
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                Text("API 仕様")
                    .font(.system(size: 13, weight: .semibold))
            }
            Divider()

            Text(L10n.text("""
            Web APIはHTTP/1.1とJSONを使うREST APIです。
            内蔵Webページや外部クライアントからサーバーを管理できます。

            主なエンドポイント：
              GET  /api/status          全サーバーの状態
              GET  /api/servers         プロファイル一覧
              POST /api/servers/{id}/start
              POST /api/servers/{id}/stop
              POST /api/servers/{id}/command
              GET  /api/servers/{id}/logs
              GET  /api/servers/{id}/whitelist
              POST /api/servers/{id}/whitelist
              DELETE /api/servers/{id}/whitelist/{uuid}

            詳細はWebAPI_Spec.txtを参照してください。
            """, """
            The Web API is an HTTP/1.1 JSON REST API.
            Manage servers from the built-in dashboard or an external client.

            Main endpoints:
              GET  /api/status          All server states
              GET  /api/servers         Profile list
              POST /api/servers/{id}/start
              POST /api/servers/{id}/stop
              POST /api/servers/{id}/command
              GET  /api/servers/{id}/logs
              GET  /api/servers/{id}/whitelist
              POST /api/servers/{id}/whitelist
              DELETE /api/servers/{id}/whitelist/{uuid}

            See WebAPI_Spec.txt for details.
            """))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .padding(12)
        .appPanel()
    }

    // MARK: - Helpers

    private func fetchLocalIP() {
        DispatchQueue.global().async {
            var address = L10n.text("取得できませんでした", "Unavailable")
            var ifaddr: UnsafeMutablePointer<ifaddrs>?
            if getifaddrs(&ifaddr) == 0 {
                var ptr = ifaddr
                while ptr != nil {
                    defer { ptr = ptr?.pointee.ifa_next }
                    let ifa = ptr!.pointee
                    let family = ifa.ifa_addr.pointee.sa_family
                    if family == UInt8(AF_INET) {
                        let name = String(cString: ifa.ifa_name)
                        if name == "en0" || name == "en1" {
                            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                                        &hostname, socklen_t(hostname.count),
                                        nil, 0, NI_NUMERICHOST)
                            address = String(cString: hostname)
                        }
                    }
                }
                freeifaddrs(ifaddr)
            }
            let resolvedAddress = address
            DispatchQueue.main.async { localIP = resolvedAddress }
        }
    }
}
