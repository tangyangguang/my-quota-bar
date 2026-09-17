import AppKit
import CryptoKit
import Foundation
import Network
import Security

// MARK: - 火山网页登录（OAuth 2.0 设备免 AK/SK）
//
// 复刻火山官方 volcengine-cli 的公开 OAuth 流程（已对未实名账号实测可用）：
// 1. App 在 127.0.0.1 起一次性本地回调服务（loopback），生成 PKCE code_verifier/challenge + state；
// 2. 打开系统浏览器到火山官方 SSO 授权页（same-device 公共客户端，无需 client_secret）；
// 3. 用户在火山官网登录授权后，浏览器跳回 http://127.0.0.1:<port>/oauth/callback?code=&state=；
// 4. 用授权码 + code_verifier 换 token：access_token 是一段 JSON 字符串，内含 15 分钟临时 STS
//    （access_key_id / secret_access_key / session_token），另有 refresh_token 与 id_token(JWT)；
// 5. 之后用 refresh_token 换新 STS（同一 /oauth/token 端点，refresh_token grant）。
//
// 已实测的硬约束：refresh_token 自签发起 48 小时硬过期，刷新不轮换、不滑动续期；
// 过期后必须重新网页授权。STS 本身约 15 分钟过期，由 WebCredentialCache 提前自动续。
enum VolcWebAuth {
    static let endpoint = "https://signin.volcengine.com"
    /// 本地 loopback 回调流的公共客户端 ID（火山官方 devtools 客户端，公开、无 secret）。
    static let clientID = "trn:signin:::devtools/same-device"
    static let scope = "Console:All:All"
    static let callbackPath = "/oauth/callback"
    static let deviceAuthorizationTimeout: TimeInterval = 300   // 5 分钟内完成网页授权
    /// refresh_token 服务端硬有效期（实测 48 小时）。解析不到 exp 时以此兜底。
    static let refreshTokenFallbackTTL: TimeInterval = 48 * 60 * 60

    // MARK: PKCE（RFC 7636）

    /// 生成 64 字节随机 code_verifier（base64url、无填充）。
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Base64URL.encode(Data(bytes))
    }

    /// code_challenge = BASECHALLENGEURL(SHA256(code_verifier))。
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Base64URL.encode(Data(digest))
    }

    /// 随机 state，防 CSRF（回调时必须原样带回）。
    static func makeState() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Base64URL.encode(Data(bytes))
    }

    // MARK: URL / 解析（纯逻辑，可单测）

    /// 拼授权 URL。redirect_uri 指向本地一次性回调服务。
    static func authorizeURL(port: Int, state: String, challenge: String) -> URL {
        var comps = URLComponents(string: endpoint + "/authorize/oauth/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri",
                         value: "http://127.0.0.1:\(port)\(callbackPath)"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return comps.url!
    }

    /// 从 id_token(JWT) 取账号 ID 与身份标记。sub=账号ID；trn 形如 trn:iam::<id>:root|user/<名>。
    static func identity(from idToken: String) -> (accountID: String, iamIdentity: String?)? {
        guard let claims = jwtPayload(idToken) else { return nil }
        let trn = claims["trn"] as? String
        let sub = (claims["sub"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // 账号 ID 优先 sub，回落从 trn 中解析。
        var accountID = sub ?? ""
        var iamIdentity: String?
        if let trn, let marker = trn.range(of: "::") {
            let rest = String(trn[marker.upperBound...])   // <accountID>:root 或 <accountID>:user/<名>
            let segments = rest.split(separator: ":", maxSplits: 1).map(String.init)
            if segments.count >= 1, accountID.isEmpty { accountID = segments[0] }
            if segments.count >= 2 {
                let resource = segments[1]
                if resource == "root" {
                    iamIdentity = "root"
                } else if resource.hasPrefix("user/") {
                    let name = String(resource.dropFirst("user/".count))
                    iamIdentity = name.isEmpty ? nil : "user:\(name)"
                }
            }
        }
        guard !accountID.isEmpty else { return nil }
        return (accountID, iamIdentity)
    }

    /// 解析 JWT 的 exp 声明（refresh_token 是带 exp 的 JWT）。
    static func jwtExpiry(_ jwt: String) -> Date? {
        guard let claims = jwtPayload(jwt),
              let exp = claims["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let data = Base64URL.decode(parts[1]),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// access_token 字段是「JSON 字符串」，内含临时 STS 三元组。
    static func parseCredential(accessToken: String) throws -> VolcCredential {
        guard let data = accessToken.data(using: .utf8),
              let sts = try? JSONDecoder().decode(AccessSTS.self, from: data) else {
            throw QuotaError.parseFailed("access_token 不是有效的 STS 凭证")
        }
        guard !sts.access_key_id.isEmpty, !sts.secret_access_key.isEmpty,
              !sts.session_token.isEmpty else {
            throw QuotaError.parseFailed("STS 凭证字段不完整")
        }
        return VolcCredential(accessKeyID: sts.access_key_id,
                              secretAccessKey: sts.secret_access_key,
                              sessionToken: sts.session_token)
    }

    fileprivate struct AccessSTS: Decodable {
        let access_key_id: String
        let secret_access_key: String
        let session_token: String
    }

    /// 注意：授权码换发的响应含 refresh_token；但用 refresh_token 续 STS 时，服务端
    /// **不回传新的 refresh_token**（48h 硬过期、不轮换、不滑动续期，实测确认），
    /// 因此该字段必须可选，否则刷新响应会整体解码失败。
    struct TokenResponse: Decodable, Sendable {
        let access_token: String
        let token_type: String?
        let expires_in: Int
        let refresh_token: String?
        let id_token: String?
    }

    // MARK: 网络

    /// 授权码换 token（首次网页登录）。
    static func exchangeCode(_ code: String, port: Int, verifier: String) async throws -> TokenResponse {
        try await tokenPost([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": "http://127.0.0.1:\(port)\(callbackPath)",
            "code_verifier": verifier
        ], reauthOnInvalidGrant: false)
    }

    /// refresh_token 换新 STS（15 分钟到期前自动调）。
    /// refresh_token 失效（48h 过期/被拒）抛 `.webReauthRequired`；网络抖动抛普通错误以保留旧值退避。
    static func refreshSTS(refreshToken: String) async throws -> TokenResponse {
        try await tokenPost([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
            "scope": scope
        ], reauthOnInvalidGrant: true)
    }

    private static func tokenPost(_ fields: [String: String],
                                  reauthOnInvalidGrant: Bool) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: endpoint + "/authorize/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = FormBody.encode(fields)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QuotaError.commandFailed("无法连接火山登录服务：\(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200...299).contains(status) {
            do {
                return try JSONDecoder().decode(TokenResponse.self, from: data)
            } catch {
                throw QuotaError.parseFailed("token 响应解析失败：\(error.localizedDescription)")
            }
        }
        // 非 2xx：尽量取 OAuth 标准错误码。
        var oauthError: String?
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            oauthError = obj["error"] as? String
        }
        let reauthCodes: Set<String> = ["invalid_grant", "invalid_token", "expired_token"]
        if reauthOnInvalidGrant,
           status == 400 || status == 401,
           let oauthError, reauthCodes.contains(oauthError) {
            throw QuotaError.webReauthRequired("网页登录已过期（\(oauthError)），请重新授权")
        }
        let detail = oauthError ?? "HTTP \(status)"
        throw QuotaError.commandFailed("token 服务返回错误：\(detail)")
    }

    // MARK: 完整登录编排

    /// 执行一次网页登录：起本地回调 → 开浏览器 → 等授权 → 换 token → 解析身份与凭证。
    /// - Parameter openBrowser: 是否自动打开系统浏览器（测试可关）。
    @discardableResult
    static func runLogin(openBrowser: Bool = true) async throws -> WebLoginResult {
        let verifier = makeVerifier()
        let state = makeState()
        let challenge = challenge(for: verifier)

        let receiver = WebCallbackReceiver()
        let port = try await receiver.start()
        let url = authorizeURL(port: port, state: state, challenge: challenge)
        if openBrowser {
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
        }

        let callback: (code: String, state: String)
        do {
            callback = try await receiver.waitForCallback(timeout: deviceAuthorizationTimeout)
        } catch {
            receiver.stop()
            throw error
        }
        receiver.stop()
        guard callback.state == state else {
            throw QuotaError.commandFailed("回调 state 不匹配，已取消（可能是无效或过期的授权请求）")
        }

        let token = try await exchangeCode(callback.code, port: port, verifier: verifier)
        let credential = try parseCredential(accessToken: token.access_token)
        guard let refreshToken = token.refresh_token, !refreshToken.isEmpty else {
            throw QuotaError.parseFailed("token 响应缺少 refresh_token")
        }
        let expiresAt = jwtExpiry(refreshToken)
            ?? Date().addingTimeInterval(refreshTokenFallbackTTL)
        let identity = token.id_token.flatMap(identity(from:))
        guard let identity else {
            throw QuotaError.parseFailed("无法从 id_token 解析账号身份")
        }
        return WebLoginResult(
            refreshToken: refreshToken,
            refreshTokenExpiresAt: expiresAt,
            accountID: identity.accountID,
            iamIdentity: identity.iamIdentity,
            credential: credential,
            stsExpiresIn: token.expires_in,
            authorizeURL: openBrowser ? nil : url
        )
    }
}

/// 一次网页登录成功后的结果。
struct WebLoginResult: Sendable {
    let refreshToken: String
    let refreshTokenExpiresAt: Date
    let accountID: String
    let iamIdentity: String?
    let credential: VolcCredential
    let stsExpiresIn: Int
    /// 仅在不自动开浏览器时回填，供 UI 展示链接。
    let authorizeURL: URL?
}

// MARK: - 临时 STS 缓存（跨 Agent/Coding 两个窗口共享，提前自动续）

/// 按账号 UUID 缓存短期 STS，15 分钟内的多个请求复用；同一账号并发刷新去重。
actor WebCredentialCache {
    static let shared = WebCredentialCache()

    private struct Entry: Sendable {
        let credential: VolcCredential
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inflight: [String: Task<VolcCredential, Error>] = [:]

    /// 返回仍有效的 STS；剩余有效期不足 90 秒则用 refresh_token 续。
    /// refresh_token 失效抛 `QuotaError.webReauthRequired`。
    func credential(accountID: String, refreshToken: String) async throws -> VolcCredential {
        if let entry = entries[accountID], entry.expiresAt.timeIntervalSinceNow > 90 {
            return entry.credential
        }
        if let task = inflight[accountID] { return try await task.value }

        let task = Task<VolcCredential, Error> {
            let response = try await VolcWebAuth.refreshSTS(refreshToken: refreshToken)
            let cred = try VolcWebAuth.parseCredential(accessToken: response.access_token)
            let ttl = max(60, response.expires_in - 60)
            self.store(accountID: accountID,
                       credential: cred,
                       expiresAt: Date().addingTimeInterval(TimeInterval(ttl)))
            return cred
        }
        inflight[accountID] = task
        defer { inflight[accountID] = nil }
        return try await task.value
    }

    /// 登录/重授成功后直接预填刚换到的 STS，省掉一次马上到来的刷新请求。
    func prefill(accountID: String, credential: VolcCredential, expiresIn: Int) {
        let ttl = max(60, expiresIn - 60)
        entries[accountID] = Entry(credential: credential,
                                   expiresAt: Date().addingTimeInterval(TimeInterval(ttl)))
    }

    private func store(accountID: String, credential: VolcCredential, expiresAt: Date) {
        entries[accountID] = Entry(credential: credential, expiresAt: expiresAt)
    }

    /// 重新授权成功或删除账号时清掉旧 STS。
    func invalidate(accountID: String) {
        entries[accountID] = nil
    }
}

// MARK: - base64url

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        s += String(repeating: "=", count: pad)
        return Data(base64Encoded: s)
    }
}

enum FormBody {
    /// RFC 3986 unreserved 字符之外一律百分号编码（client_id 含 `:` `/`，必须编码）。
    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func encode(_ fields: [String: String]) -> Data {
        let encoded = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            var v = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            v = v.replacingOccurrences(of: "%20", with: "+")  // form-urlencoded 空格用 +
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}

// MARK: - loopback 本地回调服务（仅监听 127.0.0.1，一次性）

/// 监听 127.0.0.1 随机端口，接住浏览器 OAuth 回调里的 code/state。
/// 用 Network.framework 原生实现，零第三方依赖；只接受一次请求、随机端口、校验 state。
final class WebCallbackReceiver: @unchecked Sendable {
    // 所有可变状态只在这条串行队列上访问（listener / connection 回调也派到该队列）。
    private let queue = DispatchQueue(label: "local.my-quota-bar.oauth-callback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<(code: String, state: String), Error>?
    private var didFinish = false
    private var timeoutWork: DispatchWorkItem?

    enum CallbackError: Error, LocalizedError {
        case canceled, invalidCallback, timeout
        var errorDescription: String? {
            switch self {
            case .canceled: return "授权已取消"
            case .invalidCallback: return "收到无效的浏览器回调"
            case .timeout: return "授权超时，请重新发起登录"
            }
        }
    }

    /// 绑定 127.0.0.1 随机端口并等待就绪，返回端口号。
    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: CallbackError.canceled)
                    return
                }
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: NWEndpoint.Port.any
                )
                let listener: NWListener
                do {
                    listener = try NWListener(using: params)
                } catch {
                    cont.resume(throwing: QuotaError.commandFailed(
                        "无法启动本地登录回调：\(error.localizedDescription)"))
                    return
                }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        guard let port = listener.port?.rawValue else {
                            cont.resume(throwing: QuotaError.commandFailed("无法取得本地回调端口"))
                            return
                        }
                        cont.resume(returning: Int(port))
                    case .failed(let error):
                        cont.resume(throwing: QuotaError.commandFailed(error.localizedDescription))
                    case .cancelled:
                        self?.finish(throwing: CallbackError.canceled)
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] conn in
                    self?.handle(conn)
                }
                self.listener = listener
                listener.start(queue: self.queue)
            }
        }
    }

    /// 挂起等待浏览器回传 code/state；超时自动失败。
    func waitForCallback(timeout: TimeInterval) async throws -> (code: String, state: String) {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: CallbackError.canceled)
                    return
                }
                let work = DispatchWorkItem { [weak self] in
                    self?.finish(throwing: CallbackError.timeout)
                }
                self.continuation = cont
                self.timeoutWork = work
                self.queue.asyncAfter(deadline: .now() + timeout, execute: work)
            }
        }
    }

    func stop() {
        // 仅在成功/失败收尾后调用：等待已结束，安全拆除监听。
        queue.async {
            self.timeoutWork?.cancel()
            self.timeoutWork = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
        }
    }

    // MARK: 处理一个回调连接

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respondAndFinish(connection: connection, requestHead: Data(buffer[..<range.lowerBound]))
                return
            }
            if let error {
                self.finish(throwing: QuotaError.commandFailed(error.localizedDescription))
                connection?.cancel()
                return
            }
            if isComplete {
                self.finish(throwing: CallbackError.invalidCallback)
                connection?.cancel()
                return
            }
            if let connection { self.receiveRequest(connection, buffer: buffer) }
        }
    }

    private func respondAndFinish(connection: NWConnection?, requestHead: Data) {
        guard let text = String(data: requestHead, encoding: .utf8),
              let requestLine = text.split(separator: "\r\n").first,
              let parsed = parseRequestLine(String(requestLine)) else {
            sendResponse(connection: connection, ok: false)
            finish(throwing: CallbackError.invalidCallback)
            return
        }
        sendResponse(connection: connection, ok: true)
        finish(returning: parsed)
    }

    /// 解析 `GET /oauth/callback?code=..&state=.. HTTP/1.1`。
    private func parseRequestLine(_ line: String) -> (code: String, state: String)? {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let target = parts[1]
        guard let comps = URLComponents(string: target),
              comps.path == VolcWebAuth.callbackPath else { return nil }
        let items = comps.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty,
              let state = items.first(where: { $0.name == "state" })?.value else { return nil }
        return (code, state)
    }

    private func sendResponse(connection: NWConnection?, ok: Bool) {
        let status = ok ? "200 OK" : "400 Bad Request"
        let body = ok
            ? "<!doctype html><meta charset=utf-8><title>授权成功</title>"
              + "<body style='font-family:-apple-system;text-align:center;margin-top:80px'>"
              + "<h2>授权成功</h2><p>可以回到 My Quota Bar 了。</p></body>"
            : "<!doctype html><meta charset=utf-8><body style='text-align:center;margin-top:80px'>"
              + "<h2>授权无效</h2><p>请回到 My Quota Bar 重新发起登录。</p></body>"
        let http = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(Data(body.utf8).count)\r\nConnection: close\r\n\r\n\(body)"
        connection?.send(content: Data(http.utf8), completion: .contentProcessed { [weak connection] _ in
            connection?.cancel()
        })
    }

    // MARK: 续闭结果（只允许一次）

    // 以下方法只在私有串行队列上调用，无需加锁。
    private func finish(returning value: (code: String, state: String)) {
        guard !didFinish else { return }
        didFinish = true
        timeoutWork?.cancel()
        let cont = continuation
        continuation = nil
        listener?.cancel()
        cont?.resume(returning: value)
    }

    private func finish(throwing error: Error) {
        guard !didFinish else { return }
        didFinish = true
        timeoutWork?.cancel()
        let cont = continuation
        continuation = nil
        listener?.cancel()
        cont?.resume(throwing: error)
    }
}
