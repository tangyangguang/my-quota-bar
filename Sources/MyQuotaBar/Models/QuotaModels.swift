import Foundation

// MARK: - 平台

/// 平台目录。新增平台在此加一个 case（并在对应地方接入它的认证/服务）。
/// 用 rawValue 作为持久化标识（存 JSON），显示名单独维护。
enum Platform: String, Codable, CaseIterable, Sendable {
    case volcengine
    // 将来： case siliconflow / case aliyun ...

    var displayName: String {
        switch self {
        case .volcengine: return "火山引擎"
        }
    }

    /// 容错：未知平台标识（旧版数据 / 未来降级）回落火山引擎。
    static func from(_ raw: String?) -> Platform {
        guard let raw = raw, let p = Platform(rawValue: raw) else { return .volcengine }
        return p
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
    let id: String            // 稳定标识，通常用 arkcli profile 名
    var platform: String      // 平台名，如「火山引擎」
    var defaultName: String   // 自动获取的名字（用户名）；语音拿不到则为空
    var idTail: String?       // 账号 ID 后四位（自动生成）
    var fullID: String?       // 完整账号 ID（设置页展示全量）
    var alias: String?        // 用户自定义别名（覆盖 defaultName）
    var services: [Service]

    /// 面板/菜单栏显示名：平台 · (别名或默认名) (…尾号)。空间有限只显示后四位。
    var displayName: String {
        let base: String
        if let a = alias, !a.isEmpty { base = a }
        else if !defaultName.isEmpty { base = defaultName }
        else { base = "账号" }
        if let t = idTail, !t.isEmpty { return "\(platform) · \(base) (…\(t))" }
        return "\(platform) · \(base)"
    }

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
    case speech(SpeechPack)
}

// MARK: - Agent Plan（账号A）原生结构

/// Agent Plan：多个周期窗口，每个窗口有已用/总量/百分比/重置时间。
struct AgentPlan: Equatable, Sendable {
    var tier: String          // 如 "medium"
    var edition: String       // 如 "personal"
    var unit: String          // 额度单位，如 "AFP"
    var userName: String?     // 账号名（viewer.user_name）
    var accountID: String?    // 账号 ID（viewer.account_id）
    var periods: [AgentPlanPeriod]
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
}

// MARK: - 语音服务（账号B）原生结构
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

    var errorDescription: String? {
        switch self {
        case .commandFailed(let m): return "命令执行失败：\(m)"
        case .parseFailed(let m): return "数据解析失败：\(m)"
        case .emptyResult: return "未返回任何数据"
        }
    }
}
