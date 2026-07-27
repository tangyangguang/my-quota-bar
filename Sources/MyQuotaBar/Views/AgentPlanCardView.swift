import SwiftUI

/// Agent Plan 专属展示卡片：三个窗口，每行进度条 + 百分比 + 已用/总量 + 重置时间。
struct AgentPlanCardView: View {
    let plan: AgentPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(plan.periods) { period in
                periodRow(period)
            }
        }
    }

    @ViewBuilder
    private func periodRow(_ p: AgentPlanPeriod) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.displayName)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("剩 \(Formatting.percent(p.remainingPercent))%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuotaColor.bar(p.remainingPercent))
                    .monospacedDigit()
            }

            ProgressBar(fraction: p.percent / 100, color: QuotaColor.bar(p.remainingPercent))

            HStack {
                Text("\(Formatting.raw(p.used)) / \(Formatting.raw(p.total)) \(plan.unit)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if let reset = p.resetAt {
                    Text("重置 \(DateFmt.short.string(from: reset))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// 简单进度条组件（fraction = 已用比例 0-1）。
struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

enum DateFmt {
    static let short: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d HH:mm"
        return f
    }()
}
