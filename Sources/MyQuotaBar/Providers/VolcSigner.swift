import Foundation
import CryptoKit

/// 火山引擎 OpenAPI 签名器（HMAC-SHA256，AWS V4 风格）。
/// 语音服务、Agent Plan、STS 身份查询都复用它——只是 host / region / service 不同。
struct VolcSigner: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    let host: String
    let region: String
    let service: String

    /// 生成一个已签名的请求。
    /// - method: "GET" / "POST"
    /// - query: 形如 "Action=Xxx&Version=yyyy"
    /// - body: POST 请求体；GET 传空 Data()
    func makeRequest(method: String, query: String, body: Data = Data(), timeout: TimeInterval = 20) -> URLRequest {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let xdate = fmt.string(from: Date())
        let datestamp = String(xdate.prefix(8))

        let payloadHash = sha256hex(body)
        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonicalHeaders =
            "content-type:application/json\n" +
            "host:\(host)\n" +
            "x-content-sha256:\(payloadHash)\n" +
            "x-date:\(xdate)\n"
        let canonicalRequest = [
            method, "/", query, canonicalHeaders, signedHeaders, payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(datestamp)/\(region)/\(service)/request"
        let stringToSign = [
            "HMAC-SHA256", xdate, credentialScope, sha256hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let kDate = hmac(key: Data(secretAccessKey.utf8), msg: datestamp)
        let kRegion = hmac(key: kDate, msg: region)
        let kService = hmac(key: kRegion, msg: service)
        let kSigning = hmac(key: kService, msg: "request")
        let signature = hmacHex(key: kSigning, msg: stringToSign)

        let authorization = "HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), " +
            "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var req = URLRequest(url: URL(string: "https://\(host)/?\(query)")!)
        req.httpMethod = method
        if method != "GET" { req.httpBody = body }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue(xdate, forHTTPHeaderField: "X-Date")
        req.setValue(payloadHash, forHTTPHeaderField: "X-Content-Sha256")
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = timeout
        return req
    }

    // MARK: 身份查询（STS GetCallerIdentity）——用于账号命名。

    /// 账号身份信息。
    struct Identity: Sendable {
        let accountID: String   // 账号 ID（一串数字）
        let userName: String?   // IAM 用户名（从 Trn 解析，如有）

        /// 友好名：优先 IAM 用户名，没有则用账号 ID。
        var friendlyName: String { userName ?? accountID }
    }

    /// 查询当前 AK/SK 对应的身份（账号 ID + 用户名）。失败返回 nil。
    static func fetchIdentity(accessKeyID: String, secretAccessKey: String) async -> Identity? {
        let signer = VolcSigner(
            accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
            host: "open.volcengineapi.com", region: "cn-north-1", service: "sts"
        )
        let req = signer.makeRequest(method: "GET", query: "Action=GetCallerIdentity&Version=2018-01-01", timeout: 15)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["Result"] as? [String: Any] else { return nil }
        let accountID: String
        if let id = result["AccountId"] as? NSNumber { accountID = id.stringValue }
        else if let id = result["AccountId"] as? String { accountID = id }
        else { return nil }
        // Trn 形如 trn:iam::2130011074:user/小明 → 取最后一段作为用户名
        var userName: String?
        if let trn = result["Trn"] as? String, let last = trn.split(separator: "/").last {
            let name = String(last)
            if !name.isEmpty, name != "user" { userName = name }  // “user” 是默认占位，不用
        }
        return Identity(accountID: accountID, userName: userName)
    }

    /// 兼容旧调用：只要账号 ID。
    static func fetchAccountID(accessKeyID: String, secretAccessKey: String) async -> String? {
        await fetchIdentity(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)?.accountID
    }

    private func sha256hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func hmac(key: Data, msg: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
    }
    private func hmacHex(key: Data, msg: String) -> String {
        hmac(key: key, msg: msg).map { String(format: "%02x", $0) }.joined()
    }
}
