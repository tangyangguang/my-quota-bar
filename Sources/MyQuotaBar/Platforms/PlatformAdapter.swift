import Foundation

/// 平台无关的身份结果。账号层只依赖它，不依赖某个平台的响应模型。
struct PlatformIdentity: Sendable, Equatable {
    let accountID: String
    let displayName: String?

    var suggestedAccountName: String { displayName ?? accountID }
}

/// 平台在设置页公布的凭证字段。不同平台可使用完全不同的字段集合。
struct CredentialFieldDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let secret: Bool
}

/// 平台支持的服务目录。业务数据仍由各服务自己的 Provider/卡片承载，不强行统一。
struct PlatformServiceDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let supportsMultipleInstances: Bool
}

/// 新平台接入边界：身份验证、凭证形态、服务目录都由平台适配器提供。
protocol PlatformAdapter: Sendable {
    var platform: Platform { get }
    var credentialFields: [CredentialFieldDescriptor] { get }
    var services: [PlatformServiceDescriptor] { get }

    func testIdentity(credentials: [String: String]) async throws -> PlatformIdentity
}

struct VolcenginePlatformAdapter: PlatformAdapter {
    let platform: Platform = .volcengine

    let credentialFields = [
        CredentialFieldDescriptor(id: "accessKeyID", title: "Access Key ID", secret: true),
        CredentialFieldDescriptor(id: "secretAccessKey", title: "Secret Access Key", secret: true)
    ]

    let services = [
        PlatformServiceDescriptor(id: "agent-plan", name: "Agent Plan",
                                  symbol: "a.circle", supportsMultipleInstances: false),
        PlatformServiceDescriptor(id: "speech", name: "语音服务",
                                  symbol: "waveform", supportsMultipleInstances: true)
    ]

    func testIdentity(credentials: [String: String]) async throws -> PlatformIdentity {
        guard let ak = credentials["accessKeyID"], !ak.isEmpty,
              let sk = credentials["secretAccessKey"], !sk.isEmpty else {
            throw QuotaError.parseFailed("请填写完整凭证")
        }
        let identity = try await VolcSigner.identity(accessKeyID: ak, secretAccessKey: sk)
        return PlatformIdentity(accountID: identity.accountID, displayName: identity.userName)
    }
}

/// 当前支持的平台注册表。未来加平台只新增 Adapter 并在此注册。
enum PlatformRegistry {
    private static let adapters: [Platform: any PlatformAdapter] = [
        .volcengine: VolcenginePlatformAdapter()
    ]

    static func adapter(for platform: Platform) -> (any PlatformAdapter)? {
        adapters[platform]
    }

    static var supportedPlatforms: [Platform] {
        Platform.allCases.filter { adapters[$0] != nil }
    }
}
