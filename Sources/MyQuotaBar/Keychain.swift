import Foundation
import Security

/// macOS 钥匙串存取工具，用来安全保存各账号的 AK/SK。
/// 数据存在登录钥匙串里，纯本地，不上传。
enum Keychain {
    private static let service = "local.my.quota-bar"

    /// 原地更新已有凭证；不存在时才新增。绝不先删旧值，避免新增失败导致凭证丢失。
    static func set(_ value: String, for key: String) throws {
        guard !value.isEmpty else {
            try delete(key)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PersistenceError.keychain(operation: "更新", status: updateStatus)
        }

        var add = query
        for (key, value) in attributes { add[key] = value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PersistenceError.keychain(operation: "保存", status: addStatus)
        }
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

    static func delete(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PersistenceError.keychain(operation: "删除", status: status)
        }
    }
}

enum PersistenceError: LocalizedError {
    case keychain(operation: String, status: OSStatus)
    case encodeConfiguration(String)
    case configurationLocked

    var errorDescription: String? {
        switch self {
        case .keychain(let operation, let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "钥匙串\(operation)失败：\(message)"
        case .encodeConfiguration(let message):
            return "账号配置保存失败：\(message)"
        case .configurationLocked:
            return "账号配置已锁定保护：原配置无法读取，当前操作不会覆盖原始数据。"
        }
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
    var enableSpeech: Bool    // 是否获取/展示语音服务；关闭时保留 AppID 配置
    var speechApps: [SpeechApp] // 语音应用列表（0..10，仅火山）

    init(id: String = UUID().uuidString, platform: Platform = .volcengine,
         alias: String = "", accountFullID: String? = nil,
         enableAgentPlan: Bool = false, enableSpeech: Bool? = nil,
         speechApps: [SpeechApp] = []) {
        self.id = id
        self.platform = platform
        self.alias = alias
        self.accountFullID = accountFullID
        self.enableAgentPlan = enableAgentPlan
        self.enableSpeech = enableSpeech ?? !speechApps.isEmpty
        self.speechApps = speechApps
    }

    enum CodingKeys: String, CodingKey {
        case id, platform, alias, accountFullID, enableAgentPlan, enableSpeech, speechApps
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
        // 旧配置没有开关时，有应用即视为已启用，保持升级前行为。
        enableSpeech = (try? c.decodeIfPresent(Bool.self, forKey: .enableSpeech)) ?? !speechApps.isEmpty
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(platform.rawValue, forKey: .platform)
        try c.encode(alias, forKey: .alias)
        try c.encodeIfPresent(accountFullID, forKey: .accountFullID)
        try c.encode(enableAgentPlan, forKey: .enableAgentPlan)
        try c.encode(enableSpeech, forKey: .enableSpeech)
        try c.encode(speechApps, forKey: .speechApps)
    }
}

/// 账号配置的持久化仓库：账号列表存 UserDefaults(JSON)，AK/SK 存钥匙串。
@MainActor
enum AccountStore {
    private static let listKey = "accountConfigs"
    private static let backupKey = "accountConfigs.backup"
    private(set) static var lastLoadWarning: String?
    private(set) static var writesLocked = false

    /// 主配置损坏时自动回退到最近一次有效备份，不再静默伪装成“没有账号”。
    static func load() -> [AccountConfig] {
        lastLoadWarning = nil
        writesLocked = false
        let defaults = UserDefaults.standard
        guard let primary = defaults.data(forKey: listKey) else { return [] }
        do {
            return try JSONDecoder().decode([AccountConfig].self, from: primary)
        } catch {
            if let backup = defaults.data(forKey: backupKey),
               let recovered = try? JSONDecoder().decode([AccountConfig].self, from: backup) {
                lastLoadWarning = "账号主配置损坏，已从最近备份恢复。请检查账号后重新保存。"
                return recovered
            }
            lastLoadWarning = "账号配置无法读取，原始数据已保留；写入已锁定，避免覆盖。"
            writesLocked = true
            return []
        }
    }

    /// 编码成功后才写入；覆盖前把当前有效配置留作回滚备份。
    static func save(_ list: [AccountConfig]) throws {
        guard !writesLocked else { throw PersistenceError.configurationLocked }
        let data: Data
        do {
            data = try JSONEncoder().encode(list)
        } catch {
            throw PersistenceError.encodeConfiguration(error.localizedDescription)
        }
        let defaults = UserDefaults.standard
        if let current = defaults.data(forKey: listKey),
           (try? JSONDecoder().decode([AccountConfig].self, from: current)) != nil {
            defaults.set(current, forKey: backupKey)
        }
        defaults.set(data, forKey: listKey)
        lastLoadWarning = nil
    }

    // AK/SK 存钥匙串，键按账号 ID 区分。
    static func accessKeyID(for id: String) -> String { Keychain.get("ak_\(id)") ?? "" }
    static func secretAccessKey(for id: String) -> String { Keychain.get("sk_\(id)") ?? "" }
    static func setCredentials(ak: String, sk: String, for id: String) throws {
        let akKey = "ak_\(id)"
        let skKey = "sk_\(id)"
        let oldAK = Keychain.get(akKey) ?? ""
        let oldSK = Keychain.get(skKey) ?? ""
        try Keychain.set(ak, for: akKey)
        do {
            try Keychain.set(sk, for: skKey)
        } catch {
            // 两项视作一组：第二项失败时尽力恢复第一项旧值。
            try? Keychain.set(oldAK, for: akKey)
            try? Keychain.set(oldSK, for: skKey)
            throw error
        }
    }
    static func deleteCredentials(for id: String) throws {
        try Keychain.delete("ak_\(id)")
        try Keychain.delete("sk_\(id)")
    }
}
