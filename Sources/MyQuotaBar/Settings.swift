import Foundation

/// 用户设置持久化（UserDefaults）：菜单栏显示指标、各源刷新间隔、服务隐藏、Agent Plan profile。
@MainActor
enum AppSettings {
    private static let menuBarMetricKey = "menuBarMetricID"

    /// 用户勾选的菜单栏显示指标 ID；nil 表示未设置（用默认）。
    static var selectedMetricID: String? {
        get { UserDefaults.standard.string(forKey: menuBarMetricKey) }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: menuBarMetricKey)
            } else {
                UserDefaults.standard.removeObject(forKey: menuBarMetricKey)
            }
        }
    }

    /// 刷新间隔（秒）—— 按数据源独立配置。默认 180 秒（3 分钟）。
    static func refreshInterval(for source: String) -> Int {
        let v = UserDefaults.standard.integer(forKey: "refreshInterval_\(source)")
        return v > 0 ? v : 180
    }
    static func setRefreshInterval(_ seconds: Int, for source: String) {
        UserDefaults.standard.set(seconds, forKey: "refreshInterval_\(source)")
    }

    /// 被手动隐藏的服务 ID 集合（如额度用完后不想看）。
    static var hiddenServiceIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: hiddenKey) }
    }
    private static let hiddenKey = "hiddenServiceIDs"

    /// 用户选定的 Agent Plan profile 名；nil = 未选（自动发现）。
    static var agentPlanProfile: String? {
        get { UserDefaults.standard.string(forKey: agentProfileKey) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: agentProfileKey) }
            else { UserDefaults.standard.removeObject(forKey: agentProfileKey) }
        }
    }
    private static let agentProfileKey = "agentPlanProfile"

    /// 账号别名（用户自定义）。键为账号 ID，值为别名；nil = 未设（用默认用户名）。
    static func alias(for accountID: String) -> String? {
        UserDefaults.standard.string(forKey: "accountAlias_\(accountID)")
    }
    static func setAlias(_ alias: String?, for accountID: String) {
        let key = "accountAlias_\(accountID)"
        if let a = alias, !a.isEmpty { UserDefaults.standard.set(a, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}
