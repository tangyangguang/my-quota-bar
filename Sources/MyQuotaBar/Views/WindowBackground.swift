import AppKit
import SwiftUI

/// 设置窗口的统一底色：浅色模式纯白，深色模式跟随系统。
/// 用 NSViewRepresentable 在视图进入窗口后直接设置 NSWindow，
/// 这样内容区不再是系统默认的偏灰窗口底色。
/// 重写 viewDidChangeEffectiveAppearance：系统切换浅/深色时主动刷新窗口底色
///（NSWindow.backgroundColor 同样不会因外观变化自动重新解析动态颜色）。
///
/// 另有一个必须在窗口层修掉的问题：SwiftUI `Window` 场景下，NSThemeFrame 的
/// 子视图顺序会变成 [NSTitlebarContainerView, SwiftUI hosting view]，
/// 而 hosting view 的 frame 盖满整窗（含标题栏），于是它把标题栏连红黄绿三个
/// 按钮整片压住 —— 按钮本身 isHidden=0、alpha=1、位置正常，只是看不见，
/// 窗口标题也不显示。这里在窗口上补一层“把标题栏容器重新置顶”的兜底。
struct WindowBackgroundTint: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowBackgroundView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class WindowBackgroundView: NSView {
    /// 窗口级的标题栏置顶兜底（见 TitlebarOrderFixer）。
    private var titlebarFixer: TitlebarOrderFixer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        attachTitlebarFixerIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    private func attachTitlebarFixerIfNeeded() {
        guard titlebarFixer == nil, let window else { return }
        let fixer = TitlebarOrderFixer(window: window)
        titlebarFixer = fixer
    }

    private func apply() {
        guard let window else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            window.backgroundColor = PanelColor.windowBackground
        }
    }
}

/// 保证 `NSTitlebarContainerView` 始终位于 SwiftUI hosting view 之上。
///
/// 为什么需要它：SwiftUI 把 `AppKitWindowHostingView` 的 frame 设为整窗大小
/// （含标题栏区域），并且在窗口配置过程中会重新调整子视图顺序，把 hosting view
/// 排到标题栏容器之后（= 压在上面）。只在 `viewDidMoveToWindow` 里改一次会被
/// 随后的配置覆盖掉，所以这里在窗口发生这些变化时重新置顶：
///   - 成为 key 窗口、尺寸变化、以及窗口更新（didUpdate）
/// 每次只做一次 addSubview 置顶，代价可忽略；顺序本来就对时不产生任何变化。
final class TitlebarOrderFixer {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    init(window: NSWindow) {
        self.window = window
        reorder()
        // SwiftUI 配置窗口后顺序会再次被打乱，在这些时点重新置顶。
        observe(NSWindow.didResizeNotification)
        observe(NSWindow.didBecomeKeyNotification)
        observe(NSWindow.didUpdateNotification)
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func observe(_ name: Notification.Name) {
        guard let window else { return }
        let token = NotificationCenter.default.addObserver(
            forName: name, object: window, queue: .main
        ) { [weak self] _ in
            self?.reorder()
        }
        observers.append(token)
    }

    /// 把标题栏容器移到最上层（顺序已正确时是 no-op）。
    ///
    /// 用类名字符串匹配而不是引用 `NSTitlebarContainerView`：那是 AppKit 私有类，
    /// 在 Swift 里不在作用域内。匹配不到时直接返回，不改动任何视图。
    func reorder() {
        guard let window,
              let frame = window.contentView?.superview else { return }
        let subviews = frame.subviews
        guard let titlebarIndex = subviews.firstIndex(where: {
                  NSStringFromClass(type(of: $0)) == "NSTitlebarContainerView"
              }),
              // hosting view 的特征：非标题栏容器、且 frame 盖满整个窗口
              let hostingIndex = subviews.firstIndex(where: {
                  NSStringFromClass(type(of: $0)) != "NSTitlebarContainerView"
                      && $0.frame == frame.bounds
              }),
              titlebarIndex < hostingIndex
        else { return }
        frame.addSubview(subviews[titlebarIndex], positioned: .above, relativeTo: nil)
    }
}

/// 面板/设置统一底色（浅色白、深色跟随系统），供 SwiftUI 背景使用。
enum PanelColor {
    static let windowBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.windowBackgroundColor
            : NSColor.white
    }
    static let swiftUI = Color(nsColor: windowBackground)
}
