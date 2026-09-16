// 生成 My Quota Bar 的 AppIcon：深藏青渐变底 + 白色用量环 + 薄荷绿额度弧。
// 配色与风格参考 codex-quota-menubar：开发者工具感、简洁、单一薄荷绿点缀。
// 用法：swift tools/make-icon.swift <输出目录>
// 产物：<输出目录>/icon_1024.png
import AppKit

let size = 1024
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let iconRect = rect.insetBy(dx: 96, dy: 96)

// 深藏青竖向渐变底
let bgPath = NSBezierPath(roundedRect: iconRect, xRadius: 185, yRadius: 185)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.235, green: 0.255, blue: 0.431, alpha: 1), // #3C416E 上
    NSColor(srgbRed: 0.141, green: 0.157, blue: 0.298, alpha: 1)  // #24284C 下
])!
gradient.draw(in: bgPath, angle: -90)
bgPath.addClip()

// 用量环：白色半透明轨道 + 白色主弧（已用）+ 薄荷绿弧（剩余额度）
let center = NSPoint(x: rect.midX, y: rect.midY)
let ringRadius: CGFloat = 268
let lineWidth: CGFloat = 96

func strokeArc(start: CGFloat, end: CGFloat, clockwise: Bool, color: NSColor) {
    let p = NSBezierPath()
    p.appendArc(withCenter: center, radius: ringRadius,
                startAngle: start, endAngle: end, clockwise: clockwise)
    p.lineWidth = lineWidth
    p.lineCapStyle = .round
    color.setStroke()
    p.stroke()
}

// 整圈轨道（暗白）
strokeArc(start: 0, end: 360, clockwise: false,
          color: NSColor.white.withAlphaComponent(0.16))

// 已用：白色弧，从 12 点顺时针占约 68%
let usedFraction = 0.68
strokeArc(start: 90, end: 90 - usedFraction * 360, clockwise: true,
          color: NSColor.white)

// 剩余：薄荷绿弧，紧接白色弧后（留一点间隙），占约 26%
let gap: CGFloat = 7
let mintStart = 90 - usedFraction * 360 - gap
strokeArc(start: mintStart, end: mintStart - 0.26 * 360, clockwise: true,
          color: NSColor(srgbRed: 0.471, green: 0.871, blue: 0.659, alpha: 1)) // #78DEA8

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("生成 PNG 失败\n", stderr); exit(1)
}
let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_1024.png")
try png.write(to: url)
print(url.path)
