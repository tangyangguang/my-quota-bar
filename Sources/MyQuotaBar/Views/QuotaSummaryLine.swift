import SwiftUI

/// 折叠摘要行用的单个指标：短标签 + 剩余百分比（0-100）。
struct SummaryMetric: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let remaining: Double
}

/// 折叠态的简明信息行：`5h 82%  周 95%  月 76%`，百分比按额度着色。
/// 信息量与展开态一致（同一批数字），只是浓缩成一行；字号不缩小。
struct QuotaSummaryLine: View {
    let metrics: [SummaryMetric]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(metrics) { m in
                HStack(spacing: 3) {
                    Text(m.label)
                        .foregroundStyle(.secondary)
                    Text("\(Formatting.percent(m.remaining))%")
                        .foregroundStyle(QuotaColor.bar(m.remaining))
                        .monospacedDigit()
                }
            }
        }
        .font(.caption2)
    }
}

/// 从一个账号的全部服务构建折叠摘要指标。
enum SummaryBuilder {
    static func metrics(for account: Account) -> [SummaryMetric] {
        var result: [SummaryMetric] = []
        for service in account.services {
            switch service.content {
            case .agentPlan(let plan):
                for p in plan.periods {
                    result.append(SummaryMetric(
                        id: "\(service.id)-\(p.label)",
                        label: p.shortName,
                        remaining: p.remainingPercent
                    ))
                }
            case .speech(let pack):
                guard !pack.purchased.isEmpty else { continue }
                result.append(SummaryMetric(
                    id: service.id,
                    label: pack.shortName,
                    remaining: pack.remainingPercent
                ))
            }
        }
        return result
    }

    /// 单个 Agent Plan 的摘要指标。
    static func metrics(for plan: AgentPlan, serviceID: String) -> [SummaryMetric] {
        plan.periods.map { p in
            SummaryMetric(
                id: "\(serviceID)-\(p.label)",
                label: p.shortName,
                remaining: p.remainingPercent
            )
        }
    }
}
