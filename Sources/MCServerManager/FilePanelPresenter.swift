import AppKit
import UniformTypeIdentifiers

@MainActor
enum FilePanelPresenter {
    static func chooseServerFolder(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.text("サーバーフォルダを選択してください", "Select a server folder")
        panel.prompt = L10n.text("選択", "Choose")
        present(panel, completion: completion)
    }

    static func chooseCSV(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "csv") ?? .plainText, .plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L10n.text(
            "縦1列のゲーマータグCSVを選択してください（ヘッダーなし）",
            "Select a one-column gamer-tag CSV (without a header)"
        )
        panel.prompt = L10n.text("インポート", "Import")
        present(panel, completion: completion)
    }

    private static func present(_ panel: NSOpenPanel, completion: @escaping (URL?) -> Void) {
        // MenuBarExtra windows do not cooperate reliably with nested `runModal()` loops.
        // A separately activated asynchronous panel stays key and interactive immediately.
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior.insert(.moveToActiveSpace)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.begin { response in
            Task { @MainActor in
                completion(response == .OK ? panel.url : nil)
            }
        }
    }
}
