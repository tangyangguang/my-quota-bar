import Foundation
import Security

/// macOS 钥匙串存取工具，用来安全保存各账号的 AK/SK。
///
/// 关键设计：本进程**不直接调用 Security 框架访问钥匙串**，而是通过一个签名一次、
/// 之后永不再编译的「冻结助手」credhelper-v1 访问。原因：自签名/ad-hoc 签名的图形化
/// app 访问钥匙串时，系统按二进制哈希（cdhash）记忆授权，而主程序每次重编译哈希都变，
/// 会反复弹「始终允许」。冻结助手的二进制恒定，用户只需对它授权一次即永久有效；主程序
/// 怎么重编译都不再碰钥匙串，因此不再弹窗。助手还会校验调用方必须是同一证书签名的本 app。
enum Keychain {
    private static let helperName = "credhelper-v1"

    /// 冻结助手的稳定安装路径（Application Support）。签名一次后永不覆盖。
    private static var installedHelperURL: URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("My Quota Bar", isDirectory: true)
            .appendingPathComponent(helperName)
    }

    /// 确保冻结助手已就位：已存在则直接用（保持冻结）；否则从 app 包内复制并用固定
    /// 自签证书签名一次。返回助手可执行文件 URL。
    private static func ensureHelperInstalled() -> URL? {
        let fm = FileManager.default
        if let url = installedHelperURL, fm.isExecutableFile(atPath: url.path) {
            return url
        }
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: helperName) else { return nil }
        guard let dest = installedHelperURL else { return nil }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: bundled, to: dest)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dest.path)
            sign(helper: dest)   // 签名一次；此后永不再签（二进制冻结）
            return dest
        } catch {
            return nil
        }
    }

    /// 用固定自签证书签名助手。证书私钥在生成时已授权 /usr/bin/codesign 使用，静默完成。
    /// -i 让助手与主程序同一签名标识（identifier local.my.quota-bar = 同一 DR）。
    private static func sign(helper url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "My Quota Bar Signing", "-i", "local.my.quota-bar", url.path]
        try? p.run()
        p.waitUntilExit()
    }

    /// 调用助手。返回 stdout（可能为空）表示成功；nil 表示调用失败。
    /// value 非 nil 时经 stdin 传入（避免密钥出现在命令行参数里）。
    @discardableResult
    private static func runHelper(_ command: String, key: String, value: String? = nil) -> Data? {
        guard let url = ensureHelperInstalled() else { return nil }
        let p = Process()
        p.executableURL = url
        p.arguments = [command, key]
        let stdout = Pipe()
        p.standardOutput = stdout
        p.standardError = Pipe()
        if value != nil { p.standardInput = Pipe() }
        do {
            try p.run()
            if let value, let input = p.standardInput as? Pipe {
                input.fileHandleForWriting.write(Data(value.utf8))
                try? input.fileHandleForWriting.close()
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    /// 空值=删除；非空=原地更新或新增（具体更新/新增逻辑在助手内，绝不先删旧值）。
    static func set(_ value: String, for key: String) throws {
        if value.isEmpty {
            try delete(key)
            return
        }
        guard runHelper("set", key: key, value: value) != nil else {
            throw PersistenceError.keychain(operation: "保存", status: errSecMissingValue)
        }
    }

    static func get(_ key: String) -> String? {
        guard let data = runHelper("get", key: key) else { return nil }
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.isEmpty ? nil : s
    }

    static func delete(_ key: String) throws {
        guard runHelper("delete", key: key) != nil else {
            throw PersistenceError.keychain(operation: "删除", status: errSecMissingValue)
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
