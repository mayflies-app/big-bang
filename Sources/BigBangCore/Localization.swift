import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    public var id: String { rawValue }
    /// Select the first supported language in macOS preference order.
    public static func preferred(in languages: [String] = Locale.preferredLanguages) -> AppLanguage {
        for identifier in languages {
            switch identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first {
            case "zh": return .simplifiedChinese
            case "en": return .english
            default: continue
            }
        }
        return .english
    }
    /// Native labels remain recognizable in either application language.
    public var title: String { self == .simplifiedChinese ? "简体中文" : "English" }
}

/// App-owned UI text resolves from the explicitly selected language's resource table.
public enum L10n {
    private static let lock = NSLock()
    private static var language = AppLanguage.preferred()
    static let resourceBundle = LocalizationResources.bundle(named: "BigBang_BigBangCore.bundle", fallback: { Bundle.module })

    public static var currentLanguage: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return language }
        set { lock.lock(); defer { lock.unlock() }; language = newValue }
    }

    public static func string(_ key: String, language: AppLanguage) -> String {
        LocalizationResources.string(key, language: language.rawValue, bundle: resourceBundle)
    }

    public static func string(_ key: String) -> String { string(key, language: currentLanguage) }

    public static func format(_ key: String, _ args: CVarArg..., language: AppLanguage) -> String {
        formatted(key, arguments: args, language: language)
    }

    static func formatted(_ key: String, arguments: [CVarArg], language: AppLanguage) -> String {
        LocalizationResources.format(key, language: language.rawValue, bundle: resourceBundle, arguments: arguments)
    }
}
