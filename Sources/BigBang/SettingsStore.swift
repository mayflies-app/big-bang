import AppKit
import BigBangCore
import Security

enum Keychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.mayfiles.BigBang.openai", kSecAttrAccount as String: "api-key"]
    }
    static func read() throws -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw failure(status) }
        return key
    }
    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw failure(update) }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> ValidationError {
        ValidationError(format: "钥匙串操作失败（%@）。请检查系统钥匙串授权。", arguments: [String(status)])
    }
}

@MainActor final class SettingsStore: ObservableObject {
    @Published var configuration: Configuration
    @Published var loadError: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = Configuration()
        if let data = defaults.data(forKey: "configuration") {
            do {
                let saved = try JSONDecoder().decode(Configuration.self, from: data)
                try saved.validate()
                configuration = saved
            } catch { loadError = L10n.format("保存的设置无法读取，已使用默认预设。%@", error.localizedDescription, language: configuration.language) }
        }
        L10n.currentLanguage = configuration.language
    }
    func save(_ configuration: Configuration) throws {
        try configuration.validate()
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: "configuration")
        self.configuration = configuration
        L10n.currentLanguage = configuration.language
    }
}
