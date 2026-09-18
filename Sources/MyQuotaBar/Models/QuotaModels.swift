import Foundation

// MARK: - 平台

/// 稳定平台标识。使用 struct 而非封闭 enum，旧版本也能原样保留未来平台 ID，
/// 不会把未知平台误写成火山引擎。allCases 只列出当前可新建的平台。
struct Platform: RawRepresentable, Codable, CaseIterable, Hashable, Sendable {
    let rawValue: String

    static let volcengine = Platform(rawValue: "volcengine")
    static let allCases: [Platform] = [.volcengine]

    var isSupported: Bool { Self.allCases.contains(self) }

    var displayName: String {
        switch rawValue {
        case Self.volcengine.rawValue: return "火山引擎"
        default: return "暂不支持的平台（\(rawValue)）"
        }
    }

    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 账号认证方式

/// 火山账号的凭证方式。
/// - `aksk`：用户填长期 Access Key / Secret Key（默认，老账号都是这种）。
/// - `web`：浏览器网页授权（免 AK/SK、无需实名），凭 OAuth refresh token 换 15 分钟临时 STS；
///   refresh token 硬有效期 48 小时，过期需重新网页授权。仅支持 Agent Plan / Coding Plan。
enum AuthMethod: String, Codable, Sendable {
    case aksk
    case web

    /// 宽松解码：旧数据/异常值一律回落 `.aksk`，绝不因陌生值解码失败而丢配置。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = AuthMethod(rawValue: raw) ?? .aksk
    }
}

// MARK: - 顶层：账号 → 服务
//
// 设计原则（见 PROJECT_RULES.md）：
// - 顶层按“账号”分组。
// - 每个服务「照搬原样」，不做统一格式。因此服务内容用 enum 承载不同形态，
//   每种服务有自己的数据结构，新增服务就加一个 case + 对应展示卡片。

/// 一个火山账号（一份身份 / 一份免费额度）。
struct Account: Identifiable, Equatable, Sendable {
    let id: String            // 稳定账号 UUID
    var platform: String      // 平台名，如「火山引擎」
    var defaultName: String   // 自动获取的名字（用户名）；语音拿不到则为空
    var idTail: String?       // 账号 ID 后四位（自动生成）
    var fullID: String?       // 完整账号 ID（设置页展示全量）
    var alias: String?        // 用户自定义别名（覆盖 defaultName）
    var services: [Service]
    var authMethod: AuthMethod = .aksk   // 凭证方式：AK/SK 或网页登录
    /// 网页登录 refresh token 的硬过期时刻（48h）。仅网页账号有值，用于标题行显示剩余有效期。
    var webTokenExpiresAt: Date?
    /// 网页登录的 refresh token 已过期/被拒，需到设置里重新网页授权。AK/SK 账号恒为 false。
    var webReauthNeeded: Bool = false

    /// 平台分组内的账号名。
    var accountDisplayName: String {
        let base: String
        if let a = alias, !a.isEmpty { base = a }
        else if !defaultName.isEmpty { base = defaultName }
        else { base = "账号" }
        if let t = idTail, !t.isEmpty { return "\(base) (…\(t))" }
        return base
    }

    /// 菜单栏指标等脱离平台分组的场景使用完整名称。
    var displayName: String { "\(platform) · \(accountDisplayName)" }

    /// 别名生效时用的名字（用户没设别名则回落默认名）。
    var effectiveName: String {
        if let a = alias, !a.isEmpty { return a }
        return defaultName
    }
}

/// 账号下的一项服务。内容形态各异，用 ServiceContent 承载。
struct Service: Identifiable, Equatable, Sendable {
    let id: String            // 账号内唯一，如 "agent-plan"
    var title: String         // 如「Agent Plan」
    var content: ServiceContent
    var status: ServiceStatus
    var errorMessage: String?
    var updatedAt: Date?
}

enum ServiceStatus: String, Sendable {
    case ok
    case stale        // 数据陈旧
    case error        // 本次刷新失败（保留旧值）
}

/// 各服务的原生数据形态。新增服务在此加 case。
enum ServiceContent: Equatable, Sendable {
    case agentPlan(AgentPlan)
    case codingPlan(CodingPlan)
    case speech(SpeechPack)
}

// MARK: - Agent Plan 原生结构

/// Agent Plan：多个周期窗口，每个窗口有已用/总量/百分比/重置时间。
struct AgentPlan: Equatable, Sendable {
    var tier: String          // 如 "medium"
    var edition: String       // 如 "personal"
    var unit: String          // 额度单位，如 "AFP"
    var userName: String?     // 账号名（viewer.user_name）
    var accountID: String?    // 账号 ID（viewer.account_id）
    var periods: [AgentPlanPeriod]
    /// 套餐订阅到期时刻（ListSubscribeTrade 的 EndTime）。
    /// 附加信息：查不到就是 nil（不展示），绝不影响额度主数据。
    var expiresAt: Date?

    init(tier: String, edition: String, unit: String,
         userName: String? = nil, accountID: String? = nil,
         periods: [AgentPlanPeriod], expiresAt: Date? = nil) {
        self.tier = tier
        self.edition = edition
        self.unit = unit
        self.userName = userName
        self.accountID = accountID
        self.periods = periods
        self.expiresAt = expiresAt
    }
}

struct AgentPlanPeriod: Identifiable, Equatable, Sendable {
    let label: String         // "5h" / "weekly" / "monthly"
    let used: Double
    let total: Double
    let percent: Double        // 已用百分比（0-100）
    let resetAt: Date?

    var id: String { label }

    /// 中文显示名
    var displayName: String {
        switch label {
        case "5h": return "5 小时"
        case "weekly": return "每周"
        case "monthly": return "每月"
        default: return label
        }
    }

    /// 剩余百分比（0-100）
    var remainingPercent: Double {
        max(0, min(100, 100 - percent))
    }

    /// 折叠摘要行用的短标签。
    var shortName: String {
        switch label {
        case "5h": return "5h"
        case "weekly": return "周"
        case "monthly": return "月"
        default: return displayName
        }
    }
}

// MARK: - Coding Plan 原生结构
//
// 官方 GetCodingPlanUsage 只回各周期窗口的「已用百分比」，不回绝对额度/单位；
// 照搬原样：只展示百分比 + 重置时间，不反推请求次数。

struct CodingPlan: Equatable, Sendable {
    var status: String                 // 官方 Status，如 "Running" / "Reclaimed"
    var periods: [CodingPlanPeriod]
    /// 套餐订阅到期时刻（ListSubscribeTrade 的 EndTime）。
    /// 附加信息：查不到就是 nil（不展示），绝不影响额度主数据。
    var expiresAt: Date?

    init(status: String, periods: [CodingPlanPeriod], expiresAt: Date? = nil) {
        self.status = status
        self.periods = periods
        self.expiresAt = expiresAt
    }
}

struct CodingPlanPeriod: Identifiable, Equatable, Sendable {
    let label: String          // "session" / "weekly" / "monthly"
    let usedPercent: Double    // 官方 Percent：已用百分比（0-100）
    let cap: Double            // 官方 Cap：百分比上限（实测 100）
    let resetAt: Date?         // 官方 ResetTimestamp（秒）；-1/0 = 尚未起算，为 nil

    var id: String { label }

    /// 中文显示名。官方 session 窗口即 5 小时滚动窗口，与 Agent Plan 的 5 小时口径一致。
    var displayName: String {
        switch label {
        case "session": return "5 小时"
        case "weekly": return "每周"
        case "monthly": return "每月"
        default: return label
        }
    }

    /// 剩余百分比（0-100）。官方不直接给，按 Cap - 已用 计算并裁到合法区间。
    var remainingPercent: Double {
        max(0, min(cap, cap - usedPercent))
    }

    /// 折叠摘要行用的短标签，与 Agent Plan 同款窗口保持一致。
    var shortName: String {
        switch label {
        case "session": return "5h"
        case "weekly": return "周"
        case "monthly": return "月"
        default: return displayName
        }
    }
}

// MARK: - 语音服务原生结构
//
// 层级与 Agent Plan 对齐：账号 → 服务（语音识别 / 语音合成各算一个服务）→ 剩余信息。
// 每个 SpeechPack = 一个独立服务，不再包一层“语音服务”。

struct SpeechPack: Identifiable, Equatable, Sendable {
    let title: String        // 「语音识别 ASR」/「语音合成 TTS」
    let purchased: String    // 原样，如 "20.00 小时" / "20,000 次"
    let used: String         // 原样，如 "8.79 小时" / "34 次"
    let unit: String         // "小时" / "次"
    let purchasedValue: Double
    let usedValue: Double
    let expires: String
    let type: String         // 「试用包」

    var id: String { title }

    /// 折叠摘要行用的短标签：ASR / TTS。
    var shortName: String {
        if title.contains("ASR") { return "ASR" }
        if title.contains("TTS") { return "TTS" }
        return title
    }

    /// 剩余百分比（0-100）
    var remainingPercent: Double {
        guard purchasedValue > 0 else { return 0 }
        return max(0, min(100, (purchasedValue - usedValue) / purchasedValue * 100))
    }
    /// 已用百分比（0-100）
    var usedPercent: Double {
        guard purchasedValue > 0 else { return 0 }
        return max(0, min(100, usedValue / purchasedValue * 100))
    }
}

// MARK: - 套餐订阅到期（附加信息）

/// 套餐「订阅到期」展示口径。与「额度窗口重置时间」是完全不同的概念：
/// 重置时间是每周/每月循环回血；到期时间是套餐彻底结束、之后不再有额度。
/// 因此它只展示在服务标题行，不与窗口重置倒计时混在一起。
enum PlanExpiry {
    /// 标题行文案。
    /// - 未过期：「到期 11/15 · 剩 58 天」
    /// - 已过期：「已过期」
    enum State: Equatable, Sendable {
        case active(daysLeft: Int)
        case expired
    }

    /// 按自然日差计算剩余天数：到期日 - 今天，只看日历日期、不看时刻。
    /// 例：今天 9/18，到期 11/15 → 9/19..9/30 (12) + 10 月 (31) + 11/1..11/15 (15) = 58 天。
    /// 到期当天返回 0（今天最后一天，仍算未过期）。
    static func daysLeft(until expiry: Date, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: expiry)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// 判定状态：到期时刻本身已过即视为过期。
    static func state(expiry: Date, now: Date = Date(), calendar: Calendar = .current) -> State {
        let days = daysLeft(until: expiry, now: now, calendar: calendar)
        return days < 0 ? .expired : .active(daysLeft: days)
    }

    /// 到期日期文案，只到「月/日」（与项目其它日期展示口径一致）。
    static func dateText(_ expiry: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day], from: expiry)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    /// 标题行完整文案。
    static func titleText(expiry: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch state(expiry: expiry, now: now, calendar: calendar) {
        case .expired:
            return "已过期"
        case .active(let days):
            let date = dateText(expiry, calendar: calendar)
            return days == 0 ? "到期 \(date) · 今天" : "到期 \(date) · 剩 \(days) 天"
        }
    }
}

// MARK: - 菜单栏可选指标
//
// 用户在设置里勾选“菜单栏常驻显示哪一个指标”。这里把所有服务的可选指标拍平成一个列表。

/// 一个可被选作菜单栏常驻显示的指标。
struct MenuBarMetric: Identifiable, Equatable, Sendable {
    let id: String            // 稳定 key
    let groupLabel: String    // 分组名（账号），如「火山引擎 · xxx」
    let optionLabel: String   // 短选项名，如「5 小时」
    let symbol: String        // 菜单栏图标（SF Symbol，选窄的）
    let display: MetricDisplay

    var label: String { "\(groupLabel) · \(optionLabel)" }
}

/// 指标在菜单栏的显示形态：百分比 或 纯数字。
enum MetricDisplay: Equatable, Sendable {
    case percent(Double)       // 剩余百分比 0-100
    case number(value: Double, suffix: String)

    var menuBarText: String {
        switch self {
        case .percent(let p):
            return "\(Formatting.percent(p))%"
        case .number(let v, let suffix):
            return "\(Formatting.raw(v))\(suffix)"
        }
    }
}

enum Formatting {
    /// 按原值显示：保留至多 3 位小数，去掉末尾多余零（不做 k/w 压缩）。
    /// 例：1793.747 -> "1793.747"，10000 -> "10000"，25873.646 -> "25873.646"
    static func raw(_ value: Double) -> String {
        var text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.contains(".") && text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }

    /// 百分比显示：保留至多 1 位小数（菜单栏 / 剩余标签用）。
    static func percent(_ value: Double) -> String {
        var text = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.contains(".") && text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }
}

enum QuotaError: LocalizedError, Sendable {
    case commandFailed(String)
    case parseFailed(String)
    case emptyResult
    /// 网页登录凭证失效（refresh token 48h 过期 / 被服务端拒绝），需重新网页授权。
    case webReauthRequired(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let m): return "命令执行失败：\(m)"
        case .parseFailed(let m): return "数据解析失败：\(m)"
        case .emptyResult: return "未返回任何数据"
        case .webReauthRequired(let m): return "需要重新网页授权：\(m)"
        }
    }

    /// 是否为「需重新网页授权」（用于区分普通网络失败，避免误清旧值/误提示）。
    var isWebReauthRequired: Bool {
        if case .webReauthRequired = self { return true }
        return false
    }
}
