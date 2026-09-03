import Foundation
import ServiceManagement

/// 开机自动启动（macOS 13+ 的 SMAppService）。
/// 纯系统能力，状态由系统管理，不写进我们自己的配置文件。
enum LoginItem {
    /// 当前是否已注册为登录项。
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 切换开机启动；失败抛错，由设置页弹窗提示。
    static func setEnabled(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }
}
