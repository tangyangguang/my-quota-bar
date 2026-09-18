import Foundation

/// 套餐订阅到期数据来源：火山 OpenAPI `ListSubscribeTrade`（与额度接口同一 ark 服务，AK/SK 或网页 STS 签名）。
///
/// 为什么单独一个 Provider：
/// - 到期时间与「额度窗口重置时间」是两个概念，来源也不同（额度在 GetAFPUsage / GetCodingPlanUsage）；
/// - 它属于**附加信息**：查不到（未订阅 / 接口异常）只让标题行不显示到期，绝不能让额度卡片整体报错。
///
/// 已对真实账号实测：AK/SK 与网页登录 STS 均可调用，权限无差异。
struct PlanExpiryProvider: Sendable {
    let credential: VolcCredential

    init(credential: VolcCredential) {
        self.credential = credential
    }

    init(accessKeyID: String, secretAccessKey: String) {
        self.credential = VolcCredential(accessKeyID: accessKeyID,
                                         secretAccessKey: secretAccessKey)
    }

    private let host = "ark.cn-beijing.volcengineapi.com"
    private let region = "cn-beijing"
    private let service = "ark"
    private let version = "2024-01-01"

    /// 要查的套餐类别（同一接口靠 ResourceTypes 区分）。
    enum Kind: Sendable {
        case agentPlan
        case codingPlan

        var resourceType: String {
            switch self {
            case .agentPlan: return "AgentPlan"
            case .codingPlan: return "CodingPlan"
            }
        }

        /// ResourceNames：Agent Plan 需指定 RealAgentPlanPersonal；Coding Plan 传空串（实测）。
        var resourceName: String {
            switch self {
            case .agentPlan: return "RealAgentPlanPersonal"
            case .codingPlan: return ""
            }
        }

        /// BizInfos：Agent Plan 各档位 / Coding Plan 各档位（实测口径）。
        var bizInfos: [String] {
            switch self {
            case .agentPlan: return ["small", "medium", "large", "max"]
            case .codingPlan: return ["lite", "pro"]
            }
        }
    }

    /// 查询到期时刻。未订阅 / 无有效记录 → nil（调用方据此不展示，不报错）。
    func fetchExpiry(kind: Kind) async throws -> Date? {
        let signer = VolcSigner(credential: credential, host: host, region: region, service: service)
        let body = try JSONSerialization.data(withJSONObject: [
            "BizInfos": kind.bizInfos,
            "ProjectName": "__ark_account_all__",
            "ResourceNames": [kind.resourceName],
            "ResourceTypes": [kind.resourceType]
        ])
        let req = signer.makeRequest(
            method: "POST",
            query: "Action=ListSubscribeTrade&Version=\(version)",
            body: body
        )
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw QuotaError.commandFailed("订阅接口无响应")
        }
        guard (200...299).contains(http.statusCode) else {
            throw QuotaError.commandFailed("订阅接口 HTTP \(http.statusCode)")
        }
        return try Self.parseExpiry(data)
    }

    /// 解析到期时间。任何「拿不到」的情形一律返回 nil，不抛错（附加信息不致命）。
    static func parseExpiry(_ data: Data) throws -> Date? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailed("订阅响应格式错误")
        }
        // 接口层错误仍上抛，便于诊断；但由调用方决定是否致命。
        if let meta = root["ResponseMetadata"] as? [String: Any],
           let err = meta["Error"] as? [String: Any] {
            let msg = (err["Message"] as? String) ?? (err["Code"] as? String) ?? "订阅接口错误"
            throw QuotaError.commandFailed(msg)
        }
        guard let result = root["Result"] as? [String: Any] else { return nil }
        let list = result["InfoList"] as? [[String: Any]] ?? []
        // 多条记录（如连续续费）取最晚的 EndTime 作为套餐到期时间。
        let dates = list.compactMap { $0["EndTime"] as? String }.compactMap(Self.parseTime)
        return dates.max()
    }

    /// 官方 EndTime 形如 "2026-11-15T15:59:59Z"（UTC）。
    /// 必须按真实时刻解析再转本地时区，不能直接截字符串——UTC 16:00 之后的时刻会跨到次日。
    static func parseTime(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        if let d = fmt.date(from: s) { return d }
        // 容错：带毫秒 / 带时区偏移的变体。
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        if let d = fmt.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}
