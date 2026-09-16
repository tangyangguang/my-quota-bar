import SwiftUI

/// 菜单栏弹窗背景：经典不透明面板底色（NSColor.windowBackgroundColor）。
///
/// 为什么不用毛玻璃材质：MenuBarExtra 窗口默认材质在不同 macOS 版本/外观下
/// 表现不一致——macOS 26 浅色模式下几乎是一层透明灰，后方网页文字会清晰
/// 透进来；在内容里再叠自定义 NSVisualEffectView 又会与窗口自身材质冲突，
/// 模糊不生效。改为系统标准窗口色不透明铺满，得到经典 Mac 面板的浅灰/深灰底，
/// controlBackground 卡片自然浮在上面，任何背景下都不会穿透。
struct PopoverPanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        PopoverPanelBackgroundView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PopoverPanelBackgroundView)?.applyFill()
    }
}

final class PopoverPanelBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        applyFill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        applyFill()
    }

    /// 系统浅/深色外观切换时重新解析动态颜色。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    func applyFill() {
        // 必须在当前 appearance 上下文里取 cgColor，动态颜色才会按浅/深色正确解析。
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}
