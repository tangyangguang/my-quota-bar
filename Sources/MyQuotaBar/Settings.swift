import Foundation

/// 用户设置持久化（UserDefaults）：菜单栏显示指标、各源刷新间隔。
/// 账号相关配置（别名 / 服务开关 / AppID / AK-SK）见 AccountStore。
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
}
