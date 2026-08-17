import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case japanese = "ja"
    case english = "en"
    var id: String { rawValue }
    var displayName: String { self == .japanese ? "日本語" : "English" }
}

enum L10n {
    static func text(_ ja: String, _ en: String) -> String {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.japanese.rawValue
        return raw == AppLanguage.english.rawValue ? en : ja
    }
}
