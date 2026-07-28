import Foundation
import Security

/// macOS 钥匙串存取工具，用来安全保存各账号的 AK/SK。
/// 数据存在登录钥匙串里，纯本地，不上传。
enum Keychain {
    private static let service = "local.my.quota-bar"

    static func set(_ value: String, for key: String) {
        let account = key
        let data = Data(value.utf8)

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

// MARK: - 账号配置（用户在设置里录入）

/// 一个语音应用（账号下可有多个，最多 10 个）。
struct SpeechApp: Codable, Identifiable, Equatable, Sendable {
    let id: String        // 稳定 UUID
    var appID: String     // 语音应用 AppID
    var label: String     // 可选显示名；空则用 "应用 \(appID)"

    init(id: String = UUID().uuidString, appID: String = "", label: String = "") {
        self.id = id
        self.appID = appID
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case id, appID, label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        appID = (try? c.decodeIfPresent(String.self, forKey: .appID)) ?? ""
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
    }

    /// 显示名：用户填了 label 用 label，否则「应用 <AppID>」。
    var displayLabel: String {
        label.isEmpty ? "应用 \(appID)" : label
    }
}

/// 一个平台账号的用户配置。AK/SK 存钥匙串（不落 JSON），其余非敏感字段存 UserDefaults。
///
/// 【可扩展】platform 字段已埋好；将来加其它平台时不用改结构。
/// 【防丢失】自定义 Decodable：旧版 JSON（无 platform 字段）也能正常解析，
/// 将来新增字段只要给默认值、旧配置就不会因 schema 变动而丢失。
struct AccountConfig: Codable, Identifiable, Equatable, Sendable {
    let id: String            // 稳定 UUID
    var platform: Platform    // 所属平台（默认火山引擎）
    var alias: String         // 用户自定义别名（可空）
    var accountFullID: String?// 测试连接后拿到的账号 ID（持久化，用于命名尾号）
    var enableAgentPlan: Bool // 是否获取/展示 Agent Plan（仅火山）
    var speechApps: [SpeechApp] // 语音应用列表（0..10，仅火山）

    init(id: String = UUID().uuidString, platform: Platform = .volcengine,
         alias: String = "", accountFullID: String? = nil,
         enableAgentPlan: Bool = false, speechApps: [SpeechApp] = []) {
        self.id = id
        self.platform = platform
        self.alias = alias
        self.accountFullID = accountFullID
        self.enableAgentPlan = enableAgentPlan
        self.speechApps = speechApps
    }

    enum CodingKeys: String, CodingKey {
        case id, platform, alias, accountFullID, enableAgentPlan, speechApps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // 防御式：缺失字段一律给默认值，旧配置不会解析失败
        platform = Platform.from(try c.decodeIfPresent(String.self, forKey: .platform))
        alias = (try? c.decodeIfPresent(String.self, forKey: .alias)) ?? ""
        accountFullID = try? c.decodeIfPresent(String.self, forKey: .accountFullID)
        enableAgentPlan = (try? c.decodeIfPresent(Bool.self, forKey: .enableAgentPlan)) ?? false
        speechApps = (try? c.decodeIfPresent([SpeechApp].self, forKey: .speechApps)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(platform.rawValue, forKey: .platform)
        try c.encode(alias, forKey: .alias)
        try c.encodeIfPresent(accountFullID, forKey: .accountFullID)
        try c.encode(enableAgentPlan, forKey: .enableAgentPlan)
        try c.encode(speechApps, forKey: .speechApps)
    }
}

/// 账号配置的持久化仓库：账号列表存 UserDefaults(JSON)，AK/SK 存钥匙串。
@MainActor
enum AccountStore {
    private static let listKey = "accountConfigs"

    static func load() -> [AccountConfig] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let list = try? JSONDecoder().decode([AccountConfig].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [AccountConfig]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: listKey)
        }
    }

    // AK/SK 存钥匙串，键按账号 ID 区分。
    static func accessKeyID(for id: String) -> String { Keychain.get("ak_\(id)") ?? "" }
    static func secretAccessKey(for id: String) -> String { Keychain.get("sk_\(id)") ?? "" }
    static func setCredentials(ak: String, sk: String, for id: String) {
        Keychain.set(ak, for: "ak_\(id)")
        Keychain.set(sk, for: "sk_\(id)")
    }
    static func deleteCredentials(for id: String) {
        Keychain.delete("ak_\(id)")
        Keychain.delete("sk_\(id)")
    }
}
