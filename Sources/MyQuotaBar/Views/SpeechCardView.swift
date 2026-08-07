import SwiftUI

/// 语音服务专属展示：一个资源包（ASR 或 TTS）。紧凑布局，与 Agent Plan 的窗口行对齐。
/// 服务名 + 剩余% 由外层 ServiceCardView 放在同一行；这里只画进度条 + 已用/共 + 到期。
struct SpeechCardView: View {
    let pack: SpeechPack

    var body: some View {
        if pack.purchased.isEmpty {
            Text("未配置密钥或暂无资源包")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(fraction: pack.usedPercent / 100, color: QuotaColor.bar(pack.remainingPercent))

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
