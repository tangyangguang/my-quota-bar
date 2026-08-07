import SwiftUI

/// Agent Plan 专属展示卡片：三个窗口，每行进度条 + 百分比 + 已用/总量 + 重置时间。
/// 每个 period 是一个「可钉为菜单栏」的指标，右上角浮一个 pin 小圆（不挤 UI）。
struct AgentPlanCardView: View {
    let plan: AgentPlan
    let account: Account
    let service: Service
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(plan.periods) { period in
                periodRow(period)
            }
        }
    }

    @ViewBuilder
    private func periodRow(_ p: AgentPlanPeriod) -> some View {
        let mid = model.metricID(account: account, service: service, sub: p.label)
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
                    Text(RelativeReset.text(to: reset))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("重置于 \(DateFmt.short.string(from: reset))")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .menuBarPinRow(
            isPinned: model.selectedMetricID == mid,
            action: { model.selectedMetricID = mid }
        )
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

/// 相对重置倒计时文案（他官网那种“X 后重置”）。
enum RelativeReset {
    static func text(to date: Date, now: Date = Date()) -> String {
        let secs = date.timeIntervalSince(now)
        guard secs > 0 else { return "即将重置" }
        let mins = Int(secs / 60)
        if mins < 60 {
            return "\(max(1, mins)) 分钟后重置"
        }
        let hours = mins / 60
        if hours < 24 {
            let remMin = mins % 60
            return remMin == 0 ? "\(hours) 小时后重置" : "\(hours) 小时 \(remMin) 分后重置"
        }
        let days = hours / 24
        let remHour = hours % 24
        return remHour == 0 ? "\(days) 天后重置" : "\(days) 天 \(remHour) 小时后重置"
    }
}
