import Foundation

/// 语音服务（ASR/TTS）数据来源。
/// 火山公开 OpenAPI：POST open.volcengineapi.com
///   Action=ResourcePacksStatus & Version=2023-11-07, Service=speech_saas_prod, Region=cn-north-1
/// 认证：账号级 AK/SK（复用 VolcSigner 签名）。
struct SpeechProvider: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    let appID: Int

    private let host = "open.volcengineapi.com"
    private let region = "cn-north-1"
    private let service = "speech_saas_prod"
    private let version = "2023-11-07"

    /// 语音服务原生一条资源包。
    struct Pack: Sendable {
        let instanceID: String
        let title: String
        let purchased: String
        let used: String
        let unit: String
        let purchasedValue: Double
        let usedValue: Double
        let expires: String
        let type: String
    }

    struct FetchOutcome: Sendable {
        let packs: [Pack]
        /// key 为服务标题，value 为该分项错误；ASR/TTS 互不连坐。
        let errors: [String: String]
    }

    private struct QueryOutcome: Sendable {
        let title: String
        let packs: [Pack]
        let error: String?
    }

    /// ASR 与 TTS 并行、分项容错；一个失败不会阻止另一个返回。
    func fetchOutcome() async -> FetchOutcome {
        async let asr = capture(title: "语音识别 ASR", resourceIDs: ["volc.seedasr.sauc.duration"])
        async let tts = capture(title: "语音合成 TTS", resourceIDs: ["volc.tts.default"])
        let outcomes = await [asr, tts]
        let packs = outcomes.flatMap(\.packs)
        let errors = Dictionary(uniqueKeysWithValues: outcomes.compactMap { item in
            item.error.map { (item.title, $0) }
        })
        return FetchOutcome(packs: packs, errors: errors)
    }

    func fetch() async throws -> [Pack] {
        let outcome = await fetchOutcome()
        if outcome.packs.isEmpty, let message = outcome.errors.values.first {
            throw QuotaError.commandFailed(message)
        }
        return outcome.packs
    }

    /// 测试：必须所有已查询分项都正常，部分成功会明确提示。
    func test() async -> (ok: Bool, message: String) {
        let outcome = await fetchOutcome()
        if !outcome.errors.isEmpty {
            let details = outcome.errors.sorted { $0.key < $1.key }
                .map { "\($0.key)：\($0.value)" }.joined(separator: "；")
            if outcome.packs.isEmpty { return (false, details) }
            return (false, "部分资源获取成功；\(details)")
        }
        if outcome.packs.isEmpty {
            return (false, "连接成功，但该 AppID 下没查到语音资源包（确认 AppID 是否正确）")
        }
        return (true, "已获取 \(outcome.packs.count) 个资源包：" + outcome.packs.map(\.title).joined(separator: "、"))
    }

    private func capture(title: String, resourceIDs: [String]) async -> QueryOutcome {
        do {
            return QueryOutcome(title: title,
                                packs: try await queryPacks(title: title, resourceIDs: resourceIDs),
                                error: nil)
        } catch {
            return QueryOutcome(title: title, packs: [], error: error.localizedDescription)
        }
    }

    private func signer() -> VolcSigner {
        VolcSigner(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
                   host: host, region: region, service: service)
    }

    private func queryPacks(title: String, resourceIDs: [String]) async throws -> [Pack] {
        let bodyObj: [String: Any] = [
            "AppID": appID,
            "ResourceID": resourceIDs,
            "Type": ["quota", "prepaid"],
            "PageNumber": 1,
            "PageSize": 10,
            "States": ["active"]
        ]
        let body = try JSONSerialization.data(withJSONObject: bodyObj, options: [.sortedKeys])
        let req = signer().makeRequest(method: "POST",
                                       query: "Action=ResourcePacksStatus&Version=\(version)",
                                       body: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let meta = root["ResponseMetadata"] as? [String: Any],
               let err = meta["Error"] as? [String: Any] {
                let msg = (err["Message"] as? String) ?? "HTTP \(http.statusCode)"
                throw QuotaError.commandFailed("语音接口：\(msg)")
            }
            throw QuotaError.commandFailed("语音接口 HTTP \(http.statusCode)")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailed("语音接口返回非对象")
        }
        if let meta = root["ResponseMetadata"] as? [String: Any],
           let err = meta["Error"] as? [String: Any] {
            let msg = (err["Message"] as? String) ?? (err["Code"] as? String) ?? "未知错误"
            throw QuotaError.commandFailed("语音接口：\(msg)")
        }
        guard let result = root["Result"] as? [String: Any],
              let list = result["Packs"] as? [[String: Any]] else {
            return []
        }

        return Self.parsePacks(title: title, list: list)
    }

    static func parsePacks(title: String, list: [[String: Any]]) -> [Pack] {
        list.enumerated().map { index, item in
            let purchased = (item["purchased_amount"] as? String) ?? ""
            let used = (item["current_usage"] as? String) ?? ""
            let expires = (item["expires"] as? String) ?? ""
            let type = (item["type"] as? String) ?? ""
            let instance = (item["instance_number"] as? String)
                ?? "\(title)-\(expires)-\(index)"
            let unit = purchased.contains("小时") ? "小时" : (purchased.contains("次") ? "次" : "")
            return Pack(
                instanceID: instance, title: title, purchased: purchased, used: used, unit: unit,
                purchasedValue: Self.numberFromLoose(purchased),
                usedValue: Self.numberFromLoose(used),
                expires: expires, type: type
            )
        }
    }

    /// 从 "20,000 次" / "8.79 小时" 里抽出数值。
    static func numberFromLoose(_ s: String) -> Double {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
        var num = ""
        for ch in cleaned {
            if ch.isNumber || ch == "." { num.append(ch) } else if !num.isEmpty { break }
        }
        return Double(num) ?? 0
    }
}
