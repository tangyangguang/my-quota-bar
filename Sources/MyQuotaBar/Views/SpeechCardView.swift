import SwiftUI

/// 语音服务专属展示：一个资源包（ASR 或 TTS）。紧凑布局，与 Agent Plan 的窗口行对齐。
/// 服务名 + 剩余% 由外层 ServiceCardView 放在同一行；这里只画进度条 + 已用/共 + 到期。
struct SpeechCardView: View {
    let pack: SpeechPack
    /// 紧凑样式：与 Agent Plan 紧凑周期行同排布（短名 44 宽 + 内嵌进度条 + 剩%，
    /// 进度条左右边界与 Plan 对齐）；标准样式保持原全宽进度条布局。
    var compact: Bool = false

    var body: some View {
        if pack.purchased.isEmpty {
            Text("未配置密钥或暂无资源包")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if compact {
            compactBody
        } else {
            standardBody
        }
    }

    /// 标准样式：进度条与 Agent Plan 标准周期行左右对齐（同样 8pt 行边距）。
    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressBar(fraction: pack.usedPercent / 100, color: QuotaColor.bar(pack.remainingPercent))

            detailRow
        }
        .padding(.horizontal, 8)
    }

    /// 紧凑样式：与 Agent Plan 紧凑周期行一一对应（短名/进度条/剩% 一行，明细一行）。
    private var compactBody: some View {
        // 语音无 hover/pin 背景，不加垂直边距；行间距与标准样式一致（4），高度不超标准。
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(pack.shortName)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 44, alignment: .leading)
                ProgressBar(fraction: pack.usedPercent / 100, color: QuotaColor.bar(pack.remainingPercent))
                Text("剩 \(Formatting.percent(pack.remainingPercent))%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuotaColor.bar(pack.remainingPercent))
                    .monospacedDigit()
            }

            detailRow
        }
        // 与 Agent Plan 周期行相同的水平边距，保证进度条左右边界对齐。
        .padding(.horizontal, 8)
    }

    private var detailRow: some View {
        HStack {
            Text("已用 \(pack.used) / \(pack.purchased)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if !pack.expires.isEmpty {
                Text("到期 \(pack.expires.prefix(10))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// 进度条颜色（剩余量分级），Agent Plan 和语音共用。
enum QuotaColor {
    static func bar(_ remaining: Double) -> Color {
        if remaining < 10 { return .red }
        if remaining < 30 { return .orange }
        return .green
    }
}
