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

/// 账号折叠态：一个套餐/服务占一行——服务小图标 + 该服务自己的摘要指标。
struct ServiceSummaryRow: View {
    let symbol: String
    let metrics: [SummaryMetric]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            QuotaSummaryLine(metrics: metrics)
        }
    }
}

/// 折叠摘要里按服务分的组（一组 = 折叠卡中的一行）。
struct ServiceSummaryGroup: Identifiable, Equatable, Sendable {
    let id: String
    let symbol: String
    let metrics: [SummaryMetric]
}

/// 从一个账号的全部服务构建折叠摘要指标。
enum SummaryBuilder {
    /// 按服务分组：一个套餐/服务 = 折叠卡里的一行。
    static func serviceGroups(for account: Account) -> [ServiceSummaryGroup] {
        var groups: [ServiceSummaryGroup] = []
        for service in account.services {
            switch service.content {
            case .agentPlan(let plan):
                groups.append(ServiceSummaryGroup(
                    id: service.id, symbol: "a.circle",
                    metrics: plan.periods.map { p in
                        SummaryMetric(id: "\(service.id)-\(p.label)",
                                      label: p.shortName, remaining: p.remainingPercent)
                    }
                ))
            case .codingPlan(let plan):
                groups.append(ServiceSummaryGroup(
                    id: service.id, symbol: "c.circle",
                    metrics: plan.periods.map { p in
                        SummaryMetric(id: "\(service.id)-\(p.label)",
                                      label: p.shortName, remaining: p.remainingPercent)
                    }
                ))
            case .speech(let pack):
                guard !pack.purchased.isEmpty else { continue }
                groups.append(ServiceSummaryGroup(
                    id: service.id,
                    symbol: pack.unit == "小时" ? "waveform" : "mic",
                    metrics: [SummaryMetric(id: service.id, label: pack.shortName,
                                            remaining: pack.remainingPercent)]
                ))
            }
        }
        return groups
    }

    /// 拍平的全部指标（菜单栏/其他场景如需线性列表时使用）。
    static func metrics(for account: Account) -> [SummaryMetric] {
        serviceGroups(for: account).flatMap(\.metrics)
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

    /// 单个 Coding Plan 的摘要指标。
    static func metrics(for plan: CodingPlan, serviceID: String) -> [SummaryMetric] {
        plan.periods.map { p in
            SummaryMetric(
                id: "\(serviceID)-\(p.label)",
                label: p.shortName,
                remaining: p.remainingPercent
            )
        }
    }
}
