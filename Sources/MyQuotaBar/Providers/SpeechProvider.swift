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
        let title: String
        let purchased: String
        let used: String
        let unit: String
        let purchasedValue: Double
        let usedValue: Double
        let expires: String
        let type: String
    }

    /// 拉取 ASR + TTS 两项资源包。任一失败不影响另一项。
    func fetch() async throws -> [Pack] {
        var packs: [Pack] = []
        if let asr = try await queryPack(title: "语音识别 ASR", resourceIDs: ["volc.seedasr.sauc.duration"]) {
            packs.append(asr)
        }
        if let tts = try await queryPack(title: "语音合成 TTS", resourceIDs: ["volc.tts.default"]) {
            packs.append(tts)
        }
        return packs
    }

    /// 测试：尝试拉一次语音资源包。返回成功与否 + 描述。
    func test() async -> (ok: Bool, message: String) {
        do {
            let packs = try await fetch()
            if packs.isEmpty {
                return (false, "连接成功，但该 AppID 下没查到语音资源包（确认 AppID 是否正确）")
            }
            return (true, "已获取 \(packs.count) 个资源包：" + packs.map(\.title).joined(separator: "、"))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func signer() -> VolcSigner {
        VolcSigner(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
                   host: host, region: region, service: service)
    }

    private func queryPack(title: String, resourceIDs: [String]) async throws -> Pack? {
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
              let list = result["Packs"] as? [[String: Any]],
              let first = list.first else {
            return nil
        }

        let purchased = (first["purchased_amount"] as? String) ?? ""
        let used = (first["current_usage"] as? String) ?? ""
        let expires = (first["expires"] as? String) ?? ""
        let type = (first["type"] as? String) ?? ""
        let unit = purchased.contains("小时") ? "小时" : (purchased.contains("次") ? "次" : "")

        return Pack(
            title: title, purchased: purchased, used: used, unit: unit,
            purchasedValue: Self.numberFromLoose(purchased),
            usedValue: Self.numberFromLoose(used),
            expires: expires, type: type
        )
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
