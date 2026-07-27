import Foundation
import CryptoKit

/// 账号B · 语音服务（ASR/TTS）数据来源。
/// 火山公开 OpenAPI：POST open.volcengineapi.com
///   Action=ResourcePacksStatus & Version=2023-11-07, Service=speech_saas_prod, Region=cn-north-1
/// 认证：账号级 AK/SK（火山 HMAC-SHA256 签名，AWS V4 风格）。
/// 详见 PROJECT_RULES.md「服务数据来源登记」。
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
        let title: String        // 服务名，如「语音识别」「语音合成」
        let purchased: String    // 原样字符串，如 "20.00 小时" / "20,000 次"
        let used: String         // 原样字符串，如 "8.79 小时" / "34 次"
        let unit: String         // "小时" / "次"
        let purchasedValue: Double
        let usedValue: Double
        let expires: String      // 到期时间
        let type: String         // 如「试用包」
    }

    /// 拉取 ASR + TTS 两项资源包。任一失败不影响另一项。
    func fetch() async throws -> [Pack] {
        var packs: [Pack] = []

        // ASR（语音识别，小时）
        if let asr = try await queryPack(
            title: "语音识别 ASR",
            resourceIDs: ["volc.seedasr.sauc.duration"]
        ) {
            packs.append(asr)
        }

        // TTS（语音合成，次）
        if let tts = try await queryPack(
            title: "语音合成 TTS",
            resourceIDs: ["volc.tts.default"]
        ) {
            packs.append(tts)
        }

        return packs
    }

    /// 获取当前 AK/SK 对应的账号 ID（调 sts/GetCallerIdentity）。用于语音账号命名。
    func fetchAccountID() async -> String? {
        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let xdate = fmt.string(from: now)
        let datestamp = String(xdate.prefix(8))
        let stsService = "sts"
        let query = "Action=GetCallerIdentity&Version=2018-01-01"
        let emptyHash = sha256hex(Data())
        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonicalHeaders =
            "content-type:application/json\n" +
            "host:\(host)\n" +
            "x-content-sha256:\(emptyHash)\n" +
            "x-date:\(xdate)\n"
        let canonicalRequest = ["GET", "/", query, canonicalHeaders, signedHeaders, emptyHash].joined(separator: "\n")
        let credentialScope = "\(datestamp)/\(region)/\(stsService)/request"
        let stringToSign = ["HMAC-SHA256", xdate, credentialScope, sha256hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let kDate = hmac(key: Data(secretAccessKey.utf8), msg: datestamp)
        let kRegion = hmac(key: kDate, msg: region)
        let kService = hmac(key: kRegion, msg: stsService)
        let kSigning = hmac(key: kService, msg: "request")
        let signature = hmacHex(key: kSigning, msg: stringToSign)
        let authorization = "HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var req = URLRequest(url: URL(string: "https://\(host)/?\(query)")!)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue(xdate, forHTTPHeaderField: "X-Date")
        req.setValue(emptyHash, forHTTPHeaderField: "X-Content-Sha256")
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["Result"] as? [String: Any] else { return nil }
        if let id = result["AccountId"] as? NSNumber { return id.stringValue }
        if let id = result["AccountId"] as? String { return id }
        return nil
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
        let data = try await signedPOST(action: "ResourcePacksStatus", body: body)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailed("语音接口返回非对象")
        }
        // 错误检查
        if let meta = root["ResponseMetadata"] as? [String: Any],
           let err = meta["Error"] as? [String: Any] {
            let msg = (err["Message"] as? String) ?? (err["Code"] as? String) ?? "未知错误"
            throw QuotaError.commandFailed("语音接口：\(msg)")
        }
        guard let result = root["Result"] as? [String: Any],
              let list = result["Packs"] as? [[String: Any]],
              let first = list.first else {
            return nil   // 没有该资源包，跳过
        }

        let purchased = (first["purchased_amount"] as? String) ?? ""
        let used = (first["current_usage"] as? String) ?? ""
        let expires = (first["expires"] as? String) ?? ""
        let type = (first["type"] as? String) ?? ""
        let unit = purchased.contains("小时") ? "小时" : (purchased.contains("次") ? "次" : "")

        return Pack(
            title: title,
            purchased: purchased,
            used: used,
            unit: unit,
            purchasedValue: Self.numberFromLoose(purchased),
            usedValue: Self.numberFromLoose(used),
            expires: expires,
            type: type
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

    // MARK: 火山签名 POST

    private func signedPOST(action: String, body: Data) async throws -> Data {
        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let xdate = fmt.string(from: now)
        let datestamp = String(xdate.prefix(8))

        let payloadHash = sha256hex(body)
        let canonicalQuery = "Action=\(action)&Version=\(version)"
        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonicalHeaders =
            "content-type:application/json\n" +
            "host:\(host)\n" +
            "x-content-sha256:\(payloadHash)\n" +
            "x-date:\(xdate)\n"
        let canonicalRequest = [
            "POST", "/", canonicalQuery,
            canonicalHeaders, signedHeaders, payloadHash
        ].joined(separator: "\n")

        let algorithm = "HMAC-SHA256"
        let credentialScope = "\(datestamp)/\(region)/\(service)/request"
        let stringToSign = [
            algorithm, xdate, credentialScope, sha256hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let kDate = hmac(key: Data(secretAccessKey.utf8), msg: datestamp)
        let kRegion = hmac(key: kDate, msg: region)
        let kService = hmac(key: kRegion, msg: service)
        let kSigning = hmac(key: kService, msg: "request")
        let signature = hmacHex(key: kSigning, msg: stringToSign)

        let authorization = "\(algorithm) Credential=\(accessKeyID)/\(credentialScope), " +
            "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var req = URLRequest(url: URL(string: "https://\(host)/?\(canonicalQuery)")!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue(xdate, forHTTPHeaderField: "X-Date")
        req.setValue(payloadHash, forHTTPHeaderField: "X-Content-Sha256")
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // 仍尝试把 body 交给上层解析错误信息
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let meta = root["ResponseMetadata"] as? [String: Any],
               let err = meta["Error"] as? [String: Any] {
                let msg = (err["Message"] as? String) ?? "HTTP \(http.statusCode)"
                throw QuotaError.commandFailed("语音接口：\(msg)")
            }
            throw QuotaError.commandFailed("语音接口 HTTP \(http.statusCode)")
        }
        return data
    }

    private func sha256hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func hmac(key: Data, msg: String) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key))
        return Data(mac)
    }
    private func hmacHex(key: Data, msg: String) -> String {
        hmac(key: key, msg: msg).map { String(format: "%02x", $0) }.joined()
    }
}
