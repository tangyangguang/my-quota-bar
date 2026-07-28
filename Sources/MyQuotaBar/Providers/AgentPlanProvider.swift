import Foundation

/// Agent Plan 数据来源：直接调火山 OpenAPI GetAFPUsage，用 AK/SK 签名。
/// 彻底甩掉 arkcli——朋友只需填 AK/SK，不用装任何命令行工具。
struct AgentPlanProvider: Sendable {
    let accessKeyID: String
    let secretAccessKey: String

    private let host = "ark.cn-beijing.volcengineapi.com"
    private let region = "cn-beijing"
    private let service = "ark"
    private let version = "2024-01-01"

    func fetch() async throws -> AgentPlan {
        let signer = VolcSigner(
            accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
            host: host, region: region, service: service
        )
        let req = signer.makeRequest(
            method: "GET",
            query: "Action=GetAFPUsage&Version=\(version)"
        )
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw QuotaError.commandFailed("AFP 接口无响应")
        }
        guard (200...299).contains(http.statusCode) else {
            throw QuotaError.commandFailed("AFP 接口 HTTP \(http.statusCode)")
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> AgentPlan {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["Result"] as? [String: Any] else {
            throw QuotaError.parseFailed("AFP 响应格式错误")
        }
        // 检查错误
        if let meta = root["ResponseMetadata"] as? [String: Any],
           let err = meta["Error"] as? [String: Any] {
            let msg = (err["Message"] as? String) ?? "AFP 接口错误"
            throw QuotaError.commandFailed(msg)
        }

        let planType = result["PlanType"] as? String ?? ""
        // 目前 AFP 均为 personal 版
        let edition = "personal"

        typealias RawPeriod = (label: String, data: [String: Any])
        let rawPeriods: [RawPeriod] = [
            ("5h", result["AFPFiveHour"] as? [String: Any] ?? [:]),
            ("weekly", result["AFPWeekly"] as? [String: Any] ?? [:]),
            ("monthly", result["AFPMonthly"] as? [String: Any] ?? [:]),
            // AFPDaily 可选（不一定展示）
        ]
        let periods: [AgentPlanPeriod] = rawPeriods.compactMap { (label, dict) in
            guard let quota = number(dict["Quota"]), quota > 0 else { return nil }
            let used = number(dict["Used"]) ?? 0
            let total = quota
            let percent = total > 0 ? used / total * 100 : 0
            let resetAt = number(dict["ResetTime"]).flatMap { Date(timeIntervalSince1970: $0 / 1000) }
            return AgentPlanPeriod(label: label, used: used, total: total, percent: percent, resetAt: resetAt)
        }
        guard !periods.isEmpty else { throw QuotaError.emptyResult }

        // 按 5h / weekly / monthly 排序
        let order = ["5h": 0, "weekly": 1, "monthly": 2]
        let sorted = periods.sorted { (order[$0.label] ?? 99) < (order[$1.label] ?? 99) }

        return AgentPlan(tier: planType, edition: edition, unit: "AFP",
                         userName: nil, accountID: nil, periods: sorted)
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// 测试：尝试拉一次 Agent Plan。返回成功与否 + 描述。
    func test() async -> (ok: Bool, message: String) {
        do {
            let plan = try await fetch()
            let tier = plan.tier.isEmpty ? "" : "（\(plan.tier)）"
            return (true, "已订阅 Agent Plan\(tier)，共 \(plan.periods.count) 个周期窗口")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}