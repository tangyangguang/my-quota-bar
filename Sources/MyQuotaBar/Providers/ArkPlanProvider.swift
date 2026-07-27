import Foundation

/// 账号A · Agent Plan 数据来源。
/// 命令：arkcli usage plan --profile <profile> --format json
/// 详见 PROJECT_RULES.md「服务数据来源登记」。
struct ArkPlanProvider: Sendable {
    let profile: String
    let callerName: String

    init(profile: String, callerName: String = "my-quota-bar") {
        self.profile = profile
        self.callerName = callerName
    }

    func fetch() async throws -> AgentPlan {
        guard let arkcli = ProcessRunner.locate(["arkcli"]) else {
            throw QuotaError.commandFailed("未找到 arkcli，可执行文件不存在")
        }

        let result = try await ProcessRunner.run(
            executable: arkcli,
            arguments: ["usage", "plan", "--profile", profile, "--format", "json"],
            extraEnvironment: [
                "ARKCLI_CALLER_TYPE": "ai_agent",
                "ARKCLI_CALLER_NAME": callerName,
                "ARKCLI_SKILL_NAME": "arkcli-usage"
            ],
            timeout: 30
        )

        guard result.exitCode == 0 else {
            let msg = result.stderr.isEmpty ? result.stdout : result.stderr
            throw QuotaError.commandFailed(condensed(msg))
        }

        return try Self.parse(result.stdout)
    }

    /// 解析 arkcli usage plan 的 JSON 输出。
    static func parse(_ json: String) throws -> AgentPlan {
        guard let data = json.data(using: .utf8) else {
            throw QuotaError.parseFailed("输出非 UTF-8")
        }
        let root: [String: Any]
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw QuotaError.parseFailed("顶层不是对象")
            }
            root = obj
        } catch let e as QuotaError {
            throw e
        } catch {
            throw QuotaError.parseFailed(error.localizedDescription)
        }

        guard let items = root["items"] as? [[String: Any]] else {
            throw QuotaError.parseFailed("缺少 items 字段")
        }
        guard let plan = items.first(where: { ($0["product"] as? String) == "agent-plan" }) ?? items.first else {
            throw QuotaError.emptyResult
        }

        let tier = plan["tier"] as? String ?? ""
        let edition = plan["edition"] as? String ?? ""
        let rawPeriods = plan["periods"] as? [[String: Any]] ?? []

        // 账号信息（用于面板分组标题）
        let viewer = root["viewer"] as? [String: Any]
        let userName = viewer?["user_name"] as? String
        let accountID = viewer?["account_id"] as? String

        let periods: [AgentPlanPeriod] = rawPeriods.compactMap { p in
            guard let label = p["label"] as? String else { return nil }
            let used = number(p["used"]) ?? 0
            let total = number(p["total"]) ?? 0
            let percent = number(p["percent"]) ?? (total > 0 ? used / total * 100 : 0)
            let resetAt = (p["reset_at"] as? String).flatMap(parseDate)
            return AgentPlanPeriod(
                label: label, used: used, total: total,
                percent: percent, resetAt: resetAt
            )
        }

        guard !periods.isEmpty else { throw QuotaError.emptyResult }

        // 按 5h / weekly / monthly 排序
        let order = ["5h": 0, "weekly": 1, "monthly": 2]
        let sorted = periods.sorted { (order[$0.label] ?? 99) < (order[$1.label] ?? 99) }

        return AgentPlan(tier: tier, edition: edition, unit: "AFP",
                         userName: userName, accountID: accountID, periods: sorted)
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    private func condensed(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
    }
}

// MARK: - Profile 发现

/// arkcli 本地 profile（用于设置里选 Agent Plan 账号）。
struct ArkProfile: Identifiable, Equatable, Sendable {
    let name: String          // profile 名，如 agent-plan_cn-beijing_personal
    let displayName: String   // 如 Agent Plan Medium
    let type: String          // 如 agent-plan / platform
    var id: String { name }
}

enum ArkProfileLister {
    /// 列出本机所有 arkcli profile。失败返回空数组。
    static func list() async -> [ArkProfile] {
        guard let arkcli = ProcessRunner.locate(["arkcli"]) else { return [] }
        guard let result = try? await ProcessRunner.run(
            executable: arkcli,
            arguments: ["profile", "list", "--format", "json"],
            extraEnvironment: [
                "ARKCLI_CALLER_TYPE": "ai_agent",
                "ARKCLI_CALLER_NAME": "my-quota-bar",
                "ARKCLI_SKILL_NAME": "arkcli-profile"
            ],
            timeout: 15
        ), result.exitCode == 0,
           let data = result.stdout.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = root["profiles"] as? [[String: Any]] else { return [] }
        return arr.compactMap { p in
            guard let name = p["name"] as? String else { return nil }
            return ArkProfile(
                name: name,
                displayName: (p["display_name"] as? String) ?? name,
                type: (p["type"] as? String) ?? ""
            )
        }
    }
}
