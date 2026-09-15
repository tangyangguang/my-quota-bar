import Foundation

/// Coding Plan 数据来源：火山 OpenAPI GetCodingPlanUsage（与 Agent Plan 同一 ark 服务，AK/SK 签名）。
/// 与 GetAFPUsage 的差异（已对真实账号实测）：
/// - Result.QuotaUsage 为周期窗口数组，字段 Level / Percent / Cap / ResetTimestamp；
/// - 只有「已用百分比」，没有绝对额度和单位，不反推请求次数；
/// - ResetTimestamp 是秒级（AFP 是毫秒），session 窗口未起算时为 -1；
/// - 未订阅时 HTTP 200 且 Status="Reclaimed"、无 QuotaUsage，按未订阅处理。
struct CodingPlanProvider: Sendable {
    let accessKeyID: String
    let secretAccessKey: String

    private let host = "ark.cn-beijing.volcengineapi.com"
    private let region = "cn-beijing"
    private let service = "ark"
    private let version = "2024-01-01"

    func fetch() async throws -> CodingPlan {
        let signer = VolcSigner(
            accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
            host: host, region: region, service: service
        )
        let req = signer.makeRequest(
            method: "GET",
            query: "Action=GetCodingPlanUsage&Version=\(version)"
        )
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw QuotaError.commandFailed("Coding Plan 接口无响应")
        }
        guard (200...299).contains(http.statusCode) else {
            throw QuotaError.commandFailed("Coding Plan 接口 HTTP \(http.statusCode)")
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> CodingPlan {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailed("Coding Plan 响应格式错误")
        }
        // 错误响应通常没有 Result，必须先保留官方错误信息。
        if let meta = root["ResponseMetadata"] as? [String: Any],
           let err = meta["Error"] as? [String: Any] {
            let msg = (err["Message"] as? String) ?? (err["Code"] as? String) ?? "Coding Plan 接口错误"
            throw QuotaError.commandFailed(msg)
        }
        guard let result = root["Result"] as? [String: Any] else {
            throw QuotaError.parseFailed("Coding Plan 响应缺少 Result")
        }

        let status = result["Status"] as? String ?? ""
        let rawUsage = result["QuotaUsage"] as? [[String: Any]] ?? []
        let order = ["session": 0, "weekly": 1, "monthly": 2]
        let periods: [CodingPlanPeriod] = rawUsage.compactMap { dict in
            guard let level = dict["Level"] as? String, order[level] != nil else { return nil }
            let used = number(dict["Percent"]) ?? 0
            let cap = number(dict["Cap"]) ?? 100
            // ResetTimestamp 秒级；-1/0 表示该窗口尚未起算（如订阅后还没用过的 session）。
            let reset: Date? = {
                guard let ts = number(dict["ResetTimestamp"]), ts > 0 else { return nil }
                return Date(timeIntervalSince1970: ts)
            }()
            return CodingPlanPeriod(label: level, usedPercent: used, cap: cap, resetAt: reset)
        }.sorted { (order[$0.label] ?? 99) < (order[$1.label] ?? 99) }

        guard !periods.isEmpty else { throw QuotaError.emptyResult }
        return CodingPlan(status: status, periods: periods)
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// 测试：尝试拉一次 Coding Plan。返回成功与否 + 描述。
    func test() async -> (ok: Bool, message: String) {
        do {
            let plan = try await fetch()
            return (true, "已订阅 Coding Plan，共 \(plan.periods.count) 个周期窗口")
        } catch QuotaError.emptyResult {
            return (false, "该账号未订阅 Coding Plan（接口无额度数据）")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
