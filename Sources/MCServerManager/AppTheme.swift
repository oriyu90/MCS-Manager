import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.025, green: 0.035, blue: 0.060)
    static let header = Color(red: 0.040, green: 0.060, blue: 0.105)
    static let surface = Color(red: 0.055, green: 0.080, blue: 0.135)
    static let raised = Color(red: 0.075, green: 0.110, blue: 0.180)
    static let input = Color(red: 0.020, green: 0.030, blue: 0.052)
    static let border = Color.white.opacity(0.14)
    static let borderStrong = Color(red: 0.22, green: 0.48, blue: 0.82).opacity(0.65)
    static let accent = Color(red: 0.25, green: 0.62, blue: 1.0)
    static let cyan = Color(red: 0.24, green: 0.83, blue: 0.95)
    static let muted = Color.white.opacity(0.68)
}

extension View {
    func appPanel(accent: Color? = nil) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: 10).fill(AppTheme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(accent?.opacity(0.55) ?? AppTheme.border, lineWidth: 1)
            )
    }
}
