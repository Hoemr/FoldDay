import Foundation

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let preference = "interfaceLanguage"
    static var selected: Self {
        UserDefaults.standard.string(forKey: preference).flatMap(Self.init(rawValue:)) ?? .system
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: tr("跟随系统")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    var resolved: Self {
        guard self == .system else { return self }
        for preferred in Locale.preferredLanguages {
            switch preferred.split(separator: "-").first {
            case "en": return .english
            case "zh": return .simplifiedChinese
            default: continue
            }
        }
        return .english
    }
}

private let englishStrings = Bundle.main.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:))

func tr(_ key: String, _ arguments: CVarArg...) -> String {
    let language = InterfaceLanguage.selected.resolved
    let format = language == .english ? englishStrings?.localizedString(forKey: key, value: key, table: nil) ?? key : key
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: Locale(identifier: language.rawValue), arguments: arguments)
}
