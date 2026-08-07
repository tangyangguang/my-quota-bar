import SwiftUI

/// 语音服务专属展示：一个资源包（ASR 或 TTS）。紧凑布局，与 Agent Plan 的窗口行对齐。
/// 整包是单个「可钉为菜单栏」的指标；右上角统一带 PinBadge（位置与 Agent Plan 周期行一致）。
struct SpeechCardView: View {
    let pack: SpeechPack
    let account: Account
    let service: Service
    @Bindable var model: AppModel

    var body: some View {
        let mid = model.metricID(account: account, service: service, sub: pack.title)
        let isPinned = model.selectedMetricID == mid
        VStack(alignment: .leading, spacing: 4) {
            if pack.purchased.isEmpty {
                Text("未配置密钥或暂无资源包")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    // 未配置时不需要 pin 徽章。仍是“指标行”容器以保持布局一致。
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Spacer()
                    Text("剩 \(Formatting.percent(pack.remainingPercent))%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(QuotaColor.bar(pack.remainingPercent))
                        .monospacedDigit()
                        // 为右上角 PinBadge 让出空间
                        .padding(.trailing, 22)
                }
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
        .metricRow(
            isPinned: isPinned && !pack.purchased.isEmpty,
            action: { model.selectedMetricID = mid }
        )
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
