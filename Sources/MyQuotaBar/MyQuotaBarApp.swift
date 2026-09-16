import AppKit
import SwiftUI

/// 控制 Dock 图标的动态显示：
/// 纯菜单栏应用（LSUIElement）平时不在 Dock 显示；设置窗口打开期间切换为常规模式，
/// 让用户可以从 Dock 或 Cmd+Tab 切回设置；设置窗口关闭后恢复为纯菜单栏模式。
@MainActor
final class DockVisibilityController: NSObject {
    static let shared = DockVisibilityController()

    private let settingsWindowTitle = "My Quota Bar 设置"
    private var reopenHandler: (() -> Void)?
    private var started = false

    /// 注册窗口通知。可重复调用（幂等），在应用启动和首次需要时都会执行。
    func startIfNeeded() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        // 设置窗口关闭时恢复纯菜单栏形态。
        center.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        // MenuBarExtra 弹窗关闭时会把策略重置回 .accessory，与设置窗口的切换存在竞争。
        // 因此在设置窗口成为 key 窗口（弹窗已关闭）时再确保一次 .regular。
        center.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    func setReopenHandler(_ handler: @escaping () -> Void) {
        reopenHandler = handler
    }

    /// 设置窗口打开：切到常规模式，让 Dock 显示图标。
    func settingsDidOpen() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 延迟兜底：等 MenuBarExtra 弹窗关闭、其内部策略重置完成后再切回 .regular。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.title == settingsWindowTitle else { return }
        NSApp.setActivationPolicy(.regular)
    }

    /// 点击 Dock 图标 / 重复打开应用时：设置窗口还在就前置，已关闭就重新打开。
    func handleReopen() {
        if let window = NSApp.windows.first(where: { $0.title == settingsWindowTitle }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            reopenHandler?()
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.title == settingsWindowTitle else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockVisibilityController.shared.startIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DockVisibilityController.shared.handleReopen()
        return true
    }
}

@main
@MainActor
struct MyQuotaBarApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
                .onAppear { model.refreshIfStale() }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: model.menuBarSymbol)
                    .imageScale(.small)
                Text(model.menuBarText)
                    .monospacedDigit()
            }
            .onAppear { model.startAutomaticRefresh() }
            .accessibilityLabel("My Quota Bar \(model.menuBarText)")
        }
        .menuBarExtraStyle(.window)

        // 独立设置窗口（方案 C）
        Window("My Quota Bar 设置", id: "settings") {
            SettingsSceneRoot(model: model)
        }
        .windowResizability(.contentSize)
    }
}

/// 设置窗口根视图：窗口出现期间在 Dock 显示应用图标，并注册重开处理。
private struct SettingsSceneRoot: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsWindow(model: model)
            .background(WindowBackgroundTint())
            .onAppear {
                DockVisibilityController.shared.setReopenHandler {
                    openWindow(id: "settings")
                }
                DockVisibilityController.shared.settingsDidOpen()
            }
    }
}
