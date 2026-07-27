import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var accounts: [Account] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?

    /// 用户选择在菜单栏常驻显示的指标 ID。
    var selectedMetricID: String? {
        didSet { AppSettings.selectedMetricID = selectedMetricID }
    }

    @ObservationIgnored private var timers: [RefreshSource: Timer] = [:]

    /// 刷新源（每类数据来源一个）。各自独立配置刷新间隔。
    enum RefreshSource: String, CaseIterable {
        case agentPlan = "agent-plan"
        case speech = "speech"

        var displayName: String {
            switch self {
            case .agentPlan: return "火山引擎 · Agent Plan"
            case .speech: return "火山引擎 · 语音服务"
            }
        }
    }

    /// 获取某源的刷新间隔（秒）。
    func interval(for source: RefreshSource) -> Int {
        AppSettings.refreshInterval(for: source.rawValue)
    }

    /// 设置某源的刷新间隔，并重建该源的定时器。
    func setInterval(_ seconds: Int, for source: RefreshSource) {
        AppSettings.setRefreshInterval(seconds, for: source.rawValue)
        rescheduleTimer(for: source)
    }

    // MARK: 账号 / 服务配置（新增账号/服务在这里登记）

    private let arkPlanProfile = "agent-plan_cn-beijing_personal"
    private let arkPlanFallbackName = "Agent Plan 账号"

    private let speechAccountID = "speech-account-b"
    private var speechAccountName = "火山引擎 · 语音账号"
    @ObservationIgnored private var speechAccountIDFetched = false

    // MARK: 服务可见性（设置里可勾选显示/隐藏）

    /// 隐藏的服务 ID。隐藏后面板不显示、也不进菜单栏可选项。
    var hiddenServiceIDs: Set<String> = AppSettings.hiddenServiceIDs {
        didSet { AppSettings.hiddenServiceIDs = hiddenServiceIDs }
    }

    func isServiceVisible(accountID: String, serviceID: String) -> Bool {
        !hiddenServiceIDs.contains("\(accountID)/\(serviceID)")
    }

    func setService(accountID: String, serviceID: String, visible: Bool) {
        let key = "\(accountID)/\(serviceID)"
        if visible { hiddenServiceIDs.remove(key) } else { hiddenServiceIDs.insert(key) }
    }

    /// 面板实际展示用：过滤掉被隐藏的服务（及因此变空的账号）。
    var visibleAccounts: [Account] {
        accounts.compactMap { acct in
            let services = acct.services.filter { isServiceVisible(accountID: acct.id, serviceID: $0.id) }
            guard !services.isEmpty else { return nil }
            var copy = acct
            copy.services = services
            return copy
        }
    }

    init() {
        // 默认菜单栏固定显示 5 小时窗口（用户仍可在设置里改）。
        if let saved = AppSettings.selectedMetricID {
            selectedMetricID = saved
        } else {
            selectedMetricID = "\(arkPlanProfile)/agent-plan/5h"
        }
    }

    // MARK: 菜单栏文本

    /// 所有可选指标（拍平）。设置面板用它列勾选项。
    var availableMetrics: [MenuBarMetric] {
        var metrics: [MenuBarMetric] = []
        for account in accounts {
            for service in account.services {
                if !isServiceVisible(accountID: account.id, serviceID: service.id) { continue }
                switch service.content {
                case .agentPlan(let plan):
                    for period in plan.periods {
                        metrics.append(MenuBarMetric(
                            id: metricID(account: account, service: service, sub: period.label),
                            groupLabel: account.name,
                            optionLabel: period.displayName,
                            symbol: "a.circle",   // Agent Plan 用 a 字图标，窄
                            display: .percent(period.remainingPercent)
                        ))
                    }
                case .speech(let pack):
                    metrics.append(MenuBarMetric(
                        id: metricID(account: account, service: service, sub: pack.title),
                        groupLabel: account.name,
                        optionLabel: pack.title,
                        symbol: pack.unit == "小时" ? "waveform" : "mic",
                        display: .percent(pack.remainingPercent)
                    ))
                }
            }
        }
        return metrics
    }

    /// 当前应显示在菜单栏的指标（用户选中的；没选或失效则回退到第一个）。
    var currentMetric: MenuBarMetric? {
        let all = availableMetrics
        if let id = selectedMetricID, let m = all.first(where: { $0.id == id }) {
            return m
        }
        return all.first
    }

    var menuBarText: String {
        currentMetric?.display.menuBarText ?? "--"
    }

    /// 菜单栏图标（随当前显示的指标/服务变化，选窄体积小的）。
    var menuBarSymbol: String {
        currentMetric?.symbol ?? "gauge"
    }

    private func metricID(account: Account, service: Service, sub: String) -> String {
        "\(account.id)/\(service.id)/\(sub)"
    }

    // MARK: 刷新（每源独立定时器）

    func startAutomaticRefresh() {
        guard timers.isEmpty else { return }
        refresh()   // 启动先全量拉一次
        for source in RefreshSource.allCases {
            scheduleTimer(for: source)
        }
    }

    private func scheduleTimer(for source: RefreshSource) {
        let t = Timer(timeInterval: TimeInterval(interval(for: source)), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSource(source) }
        }
        RunLoop.main.add(t, forMode: .common)
        timers[source] = t
    }

    private func rescheduleTimer(for source: RefreshSource) {
        guard timers[source] != nil else { return }
        timers[source]?.invalidate()
        timers[source] = nil
        scheduleTimer(for: source)
    }

    /// 全量刷新（手动“刷新”按钮 / 启动时）。
    func refresh() {
        refreshSource(.agentPlan)
        refreshSource(.speech)
    }

    @ObservationIgnored private var refreshing: Set<RefreshSource> = []

    /// 刷新单个源（定时器回调 / 单独触发）。
    private func refreshSource(_ source: RefreshSource) {
        guard !refreshing.contains(source) else { return }
        refreshing.insert(source)
        isRefreshing = !refreshing.isEmpty
        Task {
            switch source {
            case .agentPlan: await refreshAgentPlan()
            case .speech: await refreshSpeech()
            }
            lastRefreshAt = Date()
            refreshing.remove(source)
            isRefreshing = !refreshing.isEmpty
        }
    }

    private func refreshAgentPlan() async {
        let provider = ArkPlanProvider(profile: arkPlanProfile)
        let now = Date()
        do {
            let plan = try await provider.fetch()
            let service = Service(
                id: "agent-plan",
                title: "Agent Plan",
                content: .agentPlan(plan),
                status: .ok,
                errorMessage: nil,
                updatedAt: now
            )
            upsertAccount(id: arkPlanProfile, name: accountDisplayName(plan), service: service)
        } catch {
            // 保留上一次有效值，仅标记 error。
            markServiceError(accountID: arkPlanProfile, serviceID: "agent-plan",
                             accountName: arkPlanFallbackName, serviceTitle: "Agent Plan",
                             message: error.localizedDescription)
        }
    }

    /// 用 arkcli 返回的真实账号信息命名分组：平台 + 账号名 + 末位 ID。
    private func accountDisplayName(_ plan: AgentPlan) -> String {
        let platform = "火山引擎"
        let name = plan.userName?.trimmingCharacters(in: .whitespaces)
        let tail = plan.accountID.map { String($0.suffix(4)) }
        let who: String
        switch (name, tail) {
        case let (n?, t?) where !n.isEmpty: who = "\(n) (…\(t))"
        case let (n?, nil) where !n.isEmpty: who = n
        case let (_, t?): who = "账号 …\(t)"
        default: return arkPlanFallbackName
        }
        return "\(platform) · \(who)"
    }

    // MARK: 账号B · 语音服务

    /// 清除语音账号（用户在设置里清除密钥时）。
    func clearSpeechAccount() {
        accounts.removeAll { $0.id == speechAccountID }
        speechAccountIDFetched = false
        speechAccountName = "火山引擎 · 语音账号"
    }

    private func refreshSpeech() async {
        // 未配置 AK/SK 则不尝试（避免报错刷屏）。
        guard SpeechCredentials.isConfigured else { return }
        let ak = SpeechCredentials.accessKeyID
        let sk = SpeechCredentials.secretAccessKey
        let appID = Int(SpeechCredentials.appID) ?? 0
        let now = Date()

        let provider = SpeechProvider(accessKeyID: ak, secretAccessKey: sk, appID: appID)
        do {
            // 首次拉取账号 ID，用于命名（与 Agent Plan 对齐：平台 · 名称 (…尾号)）。
            if !speechAccountIDFetched {
                if let acctID = await provider.fetchAccountID() {
                    speechAccountName = "火山引擎 · 账号 (…\(acctID.suffix(4)))"
                }
                speechAccountIDFetched = true
            }
            let packs = try await provider.fetch()
            // 层级与 Agent Plan 对齐：每个 pack 当作一个独立服务挂在语音账号下。
            for p in packs {
                let pack = SpeechPack(title: p.title, purchased: p.purchased, used: p.used,
                                      unit: p.unit, purchasedValue: p.purchasedValue,
                                      usedValue: p.usedValue, expires: p.expires, type: p.type)
                let service = Service(
                    id: "speech-\(p.title)", title: p.title,
                    content: .speech(pack), status: .ok, errorMessage: nil, updatedAt: now
                )
                upsertAccount(id: speechAccountID, name: speechAccountName, service: service)
            }
        } catch {
            markSpeechError(message: error.localizedDescription)
        }
    }

    private func markSpeechError(message: String) {
        // 给已有的语音服务都标记 error；若从未成功过则放一个提示卡。
        if let ai = accounts.firstIndex(where: { $0.id == speechAccountID }),
           !accounts[ai].services.isEmpty {
            for si in accounts[ai].services.indices {
                accounts[ai].services[si].status = .error
                accounts[ai].services[si].errorMessage = message
            }
        } else {
            let placeholder = SpeechPack(title: "语音服务", purchased: "", used: "", unit: "",
                                         purchasedValue: 0, usedValue: 0, expires: "", type: "")
            let service = Service(
                id: "speech-placeholder", title: "语音服务",
                content: .speech(placeholder),
                status: .error, errorMessage: message, updatedAt: nil
            )
            upsertAccount(id: speechAccountID, name: speechAccountName, service: service)
        }
    }

    // MARK: 账号/服务写入

    private func upsertAccount(id: String, name: String, service: Service) {
        if let ai = accounts.firstIndex(where: { $0.id == id }) {
            if let si = accounts[ai].services.firstIndex(where: { $0.id == service.id }) {
                accounts[ai].services[si] = service
            } else {
                accounts[ai].services.append(service)
            }
            accounts[ai].name = name
        } else {
            accounts.append(Account(id: id, name: name, services: [service]))
        }
    }

    private func markServiceError(accountID: String, serviceID: String,
                                  accountName: String, serviceTitle: String, message: String) {
        if let ai = accounts.firstIndex(where: { $0.id == accountID }),
           let si = accounts[ai].services.firstIndex(where: { $0.id == serviceID }) {
            accounts[ai].services[si].status = .error
            accounts[ai].services[si].errorMessage = message
        } else {
            // 从未成功过：放一个空壳错误服务，便于面板提示。
            let service = Service(
                id: serviceID, title: serviceTitle,
                content: .agentPlan(AgentPlan(tier: "", edition: "", unit: "AFP", periods: [])),
                status: .error, errorMessage: message, updatedAt: nil
            )
            upsertAccount(id: accountID, name: accountName, service: service)
        }
    }
}
