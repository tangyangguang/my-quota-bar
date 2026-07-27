import Foundation
import Security

/// macOS 钥匙串存取工具，用来安全保存账号 B 的 AK/SK。
/// 数据存在登录钥匙串里，纯本地，不上传。
enum Keychain {
    private static let service = "local.my.quota-bar"

    static func set(_ value: String, for key: String) {
        let account = key
        let data = Data(value.utf8)

        // 先删旧的
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        guard !value.isEmpty else { return }  // 空值等于清除

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 语音账号（账号B）凭证：AK/SK + AppID。存钥匙串。
@MainActor
enum SpeechCredentials {
    private static let akKey = "volc_access_key_id"
    private static let skKey = "volc_secret_access_key"
    private static let appIDKey = "volc_speech_app_id"

    static var accessKeyID: String {
        get { Keychain.get(akKey) ?? "" }
        set { Keychain.set(newValue, for: akKey) }
    }

    static var secretAccessKey: String {
        get { Keychain.get(skKey) ?? "" }
        set { Keychain.set(newValue, for: skKey) }
    }

    /// 语音应用 AppID（用户在设置里填）。存 UserDefaults 即可（非敏感）。
    static var appID: String {
        get { UserDefaults.standard.string(forKey: appIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: appIDKey) }
    }

    static var isConfigured: Bool {
        !accessKeyID.isEmpty && !secretAccessKey.isEmpty && !appID.isEmpty
    }
}
