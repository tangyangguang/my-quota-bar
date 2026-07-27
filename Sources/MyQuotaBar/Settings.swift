import Foundation

/// 用户设置持久化（UserDefaults）。目前只有：菜单栏常驻显示哪个指标。
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
}
