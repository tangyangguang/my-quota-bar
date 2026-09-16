import SwiftUI

/// 设置窗口的统一底色：浅色模式纯白，深色模式跟随系统。
/// 用 NSViewRepresentable 在视图进入窗口后直接设置 NSWindow，
/// 这样标题栏与内容区底色一致，不再是系统默认的偏灰窗口底。
/// 重写 viewDidChangeEffectiveAppearance：系统切换浅/深色时主动刷新窗口底色
///（NSWindow.backgroundColor 同样不会因外观变化自动重新解析动态颜色）。
struct WindowBackgroundTint: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowBackgroundView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class WindowBackgroundView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    private func apply() {
        guard let window else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            window.backgroundColor = PanelColor.windowBackground
        }
        window.titlebarAppearsTransparent = true
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
