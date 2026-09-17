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
        reconcileWindowHeight()
    }

    /// 校正 MenuBarExtraWindow 高度只增不减的问题。
    ///
    /// 现象：弹窗内容变矮（折叠账号）后，MenuBarExtraWindow 不回缩、甚至在瞬时
    /// 布局中被撑得更高；SwiftUI 内容在变高的窗口里垂直居中，而不透明底色只铺满
    /// 内容本身，于是面板上沿离开菜单栏、下沿悬空，上下露出透明窗口、后方内容穿透。
    /// 这里在布局时把窗口回缩到内容真实高度，顶边不动（始终贴着菜单栏），只回收
    /// 系统多留的高度；窗口的正常增长仍交给系统，不干预。
    private func reconcileWindowHeight() {
        guard let window = window,
              String(describing: type(of: window)).contains("MenuBarExtraWindow") else { return }
        let target = bounds.height
        guard target > 1, window.frame.height > target + 1 else { return }
        var frame = window.frame
        frame.origin.y += frame.height - target   // 保持顶边不动，向下回缩
        frame.size.height = target
        window.setFrame(frame, display: false, animate: false)
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
