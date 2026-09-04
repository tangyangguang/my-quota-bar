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

    /// 一次性迁移：把已有项的访问控制列表（ACL）重写为只信任当前应用身份。
    /// 背景：ad-hoc 签名时期创建的项，ACL 记录的是旧（cdhash）身份；换成固定证书
    /// 签名后旧 ACL 不会自动更新，导致每次启动/重建都弹授权。重写后 ACL 锚定到
    /// 当前应用的 designated requirement（证书指纹），同证书签名的应用以后访问
    /// 不再弹窗。**数据不读、不改、不经内存**，只替换访问控制。
    /// - Returns: true = 项不存在（无需迁移）或重写成功；false = 用户拒绝或失败（下次启动再试）。
    @discardableResult
    static func resetAccess(for key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let probe = SecItemCopyMatching(query as CFDictionary, nil)
        if probe == errSecItemNotFound { return true }
        guard probe == errSecSuccess else { return false }

        var trustedApp: SecTrustedApplication?
        let trustStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApp)
        guard trustStatus == errSecSuccess, let trusted = trustedApp else { return false }
        var access: SecAccess?
        let aclStatus = SecAccessCreate("My Quota Bar" as CFString,
                                       [trusted] as CFArray, &access)
        guard aclStatus == errSecSuccess, let access else { return false }

        return SecItemUpdate(query as CFDictionary,
                             [kSecAttrAccess: access] as CFDictionary) == errSecSuccess
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
///
/// 每个应用内部的 ASR（语音识别）与 TTS（语音合成）各自独立开关：
/// 例如 ASR 额度用尽（0%）时可单独关掉 ASR、只保留 TTS，面板就不再显示红色的 ASR 卡。
struct SpeechApp: Codable, Identifiable, Equatable, Sendable {
    let id: String        // 稳定 UUID
    var appID: String     // 语音应用 AppID
    var label: String     // 可选显示名；空则用 "应用 \(appID)"
    var enableASR: Bool   // 是否获取/展示该应用的语音识别（ASR）额度
    var enableTTS: Bool   // 是否获取/展示该应用的语音合成（TTS）额度

    init(id: String = UUID().uuidString, appID: String = "", label: String = "",
         enableASR: Bool = true, enableTTS: Bool = true) {
        self.id = id
        self.appID = appID
        self.label = label
        self.enableASR = enableASR
        self.enableTTS = enableTTS
    }

    /// AppID 是否为有效数字（>0）。
    var hasValidAppID: Bool {
        Int(appID.trimmingCharacters(in: .whitespaces)).map { $0 > 0 } ?? false
    }

    /// 是否实际参与取数/展示：AppID 有效且 ASR/TTS 至少开一个。全不勾 = 不拉数、不显示。
    var isActive: Bool { hasValidAppID && (enableASR || enableTTS) }

    /// 显示名：用户填了 label 用 label，否则「应用 <AppID>」。
    var displayLabel: String {
        label.isEmpty ? "应用 \(appID)" : label
    }
}

/// 一个平台账号的用户配置。AK/SK 存钥匙串（不落 JSON），其余非敏感字段存 UserDefaults。
///
/// 语音是否启用由 `speechApps` 派生：存在「AppID 有效且 ASR/TTS 至少开一个」的应用即为启用，
/// 不再有独立的语音总开关。Codable 由编译器合成；历史遗留的未知字段（如 enableSpeech）
/// 解码时自动忽略，不会报错。
struct AccountConfig: Codable, Identifiable, Equatable, Sendable {
    let id: String              // 稳定 UUID（钥匙串按它存取 AK/SK，不可变）
    var platform: Platform      // 所属平台
    var alias: String           // 用户自定义别名（可空）
    var accountFullID: String?  // 测试连接后拿到的账号 ID（持久化，用于命名尾号）
    var enableAgentPlan: Bool   // 是否获取/展示 Agent Plan
    var speechApps: [SpeechApp] // 语音应用列表（0..10）
    var iamIdentity: String?    // 身份标记："root"（主账号）/ "user:<名>"（子用户）；测试连接后写入

    init(id: String = UUID().uuidString, platform: Platform = .volcengine,
         alias: String = "", accountFullID: String? = nil,
         enableAgentPlan: Bool = false, speechApps: [SpeechApp] = [],
         iamIdentity: String? = nil) {
        self.id = id
        self.platform = platform
        self.alias = alias
        self.accountFullID = accountFullID
        self.enableAgentPlan = enableAgentPlan
        self.speechApps = speechApps
        self.iamIdentity = iamIdentity
    }

    /// 是否有启用中的语音应用。
    var hasActiveSpeech: Bool { speechApps.contains { $0.isActive } }

    /// 该账号是否有任何会在面板展示的服务。
    var hasAnyService: Bool { enableAgentPlan || hasActiveSpeech }

    /// 身份徽章文案：主账号 / 子用户 · 名称；未知返回 nil。
    var identityBadge: String? {
        guard let iamIdentity else { return nil }
        if iamIdentity == "root" { return "主账号" }
        if iamIdentity.hasPrefix("user:") {
            let name = String(iamIdentity.dropFirst("user:".count))
            return name.isEmpty ? "子用户" : "子用户 · \(name)"
        }
        return nil
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
