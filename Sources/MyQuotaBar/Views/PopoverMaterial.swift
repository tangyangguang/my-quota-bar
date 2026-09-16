import SwiftUI

/// 菜单栏弹窗背景：毛玻璃之上叠一层自适应外观的底色。
///
/// 为什么需要显式背景：设置窗口打开时应用会切换为常规前台模式（在 Dock 显示
/// 图标），且弹窗后方经常是深色窗口，默认 MenuBarExtra 材质在这些情况下会明显
/// 发灰；而面板内的卡片是白色，灰底白卡对比刺眼。
///
/// 注意：CALayer.backgroundColor 会缓存解析后的颜色，系统切换浅/深色外观时
/// 不会自动重新解析，因此用自定义视图重写 viewDidChangeEffectiveAppearance，
/// 在外观变化时主动按当前外观重新取色。
struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = PopoverBackgroundView()
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PopoverBackgroundView)?.applyTint()
    }
}

final class PopoverBackgroundView: NSView {
    private let blur = NSVisualEffectView()
    private let tint = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]

        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)

        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)

        applyTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        blur.frame = bounds
        tint.frame = bounds
        applyTint()
    }

    /// 系统浅/深色外观切换时重新解析动态颜色。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    func applyTint() {
        // 必须在当前 appearance 上下文里取 cgColor，动态颜色才会按浅/深色正确解析。
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint.layer?.backgroundColor = Self.tintColor.cgColor
        }
    }

    /// 浅色：叠 88% 白，得到干净近白面板；深色：不叠加，露出原生深毛玻璃。
    private static let tintColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.clear
            : NSColor.white.withAlphaComponent(0.88)
    }
}
