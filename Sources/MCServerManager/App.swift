import SwiftUI

@main
struct MCServerManagerApp: App {
    @StateObject private var manager = ServerManager()

    var body: some Scene {
        MenuBarExtra {
            MainView()
                .environmentObject(manager)
                .environment(\.locale, Locale(identifier: manager.appLanguage.rawValue))
                .preferredColorScheme(.dark)
                .tint(AppTheme.accent)
                .frame(width: 540, height: 620)
        } label: {
            StatusBarIcon(status: manager.anyRunning ? .running : manager.status)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct StatusBarIcon: View {
    let status: ServerStatus

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "cube.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)

            Circle()
                .fill(status.dotColor)
                .frame(width: 6, height: 6)
                .offset(x: 3, y: -3)
        }
        .frame(width: 22, height: 18)
    }
}
