import AppKit
import Foundation
import Network
import Observation

@MainActor
@Observable
final class AppModel {
    /// 展示用账号列表（由已配置账号 + 拉取到的数据构建）。
    private(set) var accounts: [Account] = [] {
        didSet { rebuildMetrics() }
    }
    /// 用户配置的账号（持久化）。
    private(set) var accountConfigs: [AccountConfig] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?

    /// 用户选择在菜单栏常驻显示的指标 ID。
    var selectedMetricID: String? {
        didSet { AppSettings.selectedMetricID = selectedMetricID }
    }

    @ObservationIgnored private var timers: [RefreshSource: Timer] = [:]
    /// 账号 ID -> 该账号完整账号 ID（STS 查得，用于命名尾号）。
    @ObservationIgnored private var accountFullID_: [String: String] = [:]

    /// 刷新源（按服务类型分类，用于独立配置刷新间隔）。
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

    /// 各源刷新间隔（秒）。observable 存储属性，写时同步落 UserDefaults；
    /// 这样 SwiftUI Picker 能直接观察到变化、不会回弹。
    var refreshIntervals: [String: Int] = [:]

    func interval(for source: RefreshSource) -> Int {
        refreshIntervals[source.rawValue] ?? AppSettings.refreshInterval(for: source.rawValue)
    }

    func setInterval(_ seconds: Int, for source: RefreshSource) {
        refreshIntervals[source.rawValue] = seconds
        AppSettings.setRefreshInterval(seconds, for: source.rawValue)
        rescheduleTimer(for: source)
    }

    init() {
        selectedMetricID = AppSettings.selectedMetricID
        for source in RefreshSource.allCases {
            refreshIntervals[source.rawValue] = AppSettings.refreshInterval(for: source.rawValue)
        }
        accountConfigs = AccountStore.load()
        for c in accountConfigs {
            if let full = c.accountFullID { accountFullID_[c.id] = full }
        }
    }

    // MARK: 账号配置 CRUD（设置窗口调用）

    /// 测试一对 AK/SK：验证身份并拿回账号信息。返回 (成功, 身份信息或错误描述)。
    func testCredentials(ak: String, sk: String) async -> (ok: Bool, identity: VolcSigner.Identity?, message: String) {
        let a = ak.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = sk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !s.isEmpty else { return (false, nil, "请先填写 AK 和 SK") }
        if let identity = await VolcSigner.fetchIdentity(accessKeyID: a, secretAccessKey: s) {
            return (true, identity, "连接成功，账号 ID：\(identity.accountID)")
        }
        return (false, nil, "连接失败：AK/SK 无效或无权限（请核对后重试）")
    }

    /// 测试某账号的 Agent Plan（用传入的 AK/SK，不依赖已保存）。
    func testAgentPlan(ak: String, sk: String) async -> (ok: Bool, message: String) {
        await AgentPlanProvider(accessKeyID: ak.trimmingCharacters(in: .whitespaces),
                                secretAccessKey: sk.trimmingCharacters(in: .whitespaces)).test()
    }

    /// 测试某语音应用（用传入的 AK/SK + AppID）。
    func testSpeechApp(ak: String, sk: String, appID: String) async -> (ok: Bool, message: String) {
        guard let id = Int(appID.trimmingCharacters(in: .whitespaces)), id > 0 else {
            return (false, "AppID 需为数字")
        }
        return await SpeechProvider(accessKeyID: ak.trimmingCharacters(in: .whitespaces),
                                    secretAccessKey: sk.trimmingCharacters(in: .whitespaces),
                                    appID: id).test()
    }

    /// 新增账号。持久化配置 + 凭证，然后刷新。返回新账号 ID。
    @discardableResult
    func addAccount(platform: Platform = .volcengine, alias: String, ak: String, sk: String,
                    accountFullID: String?, enableAgentPlan: Bool, speechApps: [SpeechApp]) -> String {
        let config = AccountConfig(platform: platform, alias: alias, accountFullID: accountFullID,
                                   enableAgentPlan: enableAgentPlan, speechApps: speechApps)
        AccountStore.setCredentials(ak: ak, sk: sk, for: config.id)
        if let full = accountFullID { accountFullID_[config.id] = full }
        accountConfigs.append(config)
        AccountStore.save(accountConfigs)
        refreshAccountConfig(config)
        return config.id
    }

    /// 更新已有账号。ak/sk 传空表示不改动原凭证。
    func updateAccount(id: String, alias: String, ak: String?, sk: String?, accountFullID: String?,
                       enableAgentPlan: Bool, speechApps: [SpeechApp]) {
        guard let idx = accountConfigs.firstIndex(where: { $0.id == id }) else { return }
        accountConfigs[idx].alias = alias
        accountConfigs[idx].enableAgentPlan = enableAgentPlan
        accountConfigs[idx].speechApps = speechApps
        if let full = accountFullID { accountConfigs[idx].accountFullID = full }
        if let ak = ak, let sk = sk {
            AccountStore.setCredentials(ak: ak, sk: sk, for: id)
        }
        AccountStore.save(accountConfigs)
        if let full = accountConfigs[idx].accountFullID { accountFullID_[id] = full }
        // 删掉已不存在的展示服务（先清空该账号，重新拉）
        accounts.removeAll { $0.id == id }
        refreshAccountConfig(accountConfigs[idx])
    }

    /// 删除账号：清凭证、清配置、从面板移除。
    func removeAccount(id: String) {
        AccountStore.deleteCredentials(for: id)
        accountConfigs.removeAll { $0.id == id }
        AccountStore.save(accountConfigs)
        accounts.removeAll { $0.id == id }
        accountFullID_[id] = nil
    }

    func credentials(for id: String) -> (ak: String, sk: String) {
        (AccountStore.accessKeyID(for: id), AccountStore.secretAccessKey(for: id))
    }

    // MARK: 菜单栏文本

    /// 所有可选指标（拍平）。缓存，仅数据变化时重建。
    private(set) var availableMetrics: [MenuBarMetric] = []

    private func rebuildMetrics() {
        var metrics: [MenuBarMetric] = []
        for account in accounts {
            for service in account.services {
                switch service.content {
                case .agentPlan(let plan):
                    for period in plan.periods {
                        metrics.append(MenuBarMetric(
                            id: metricID(account: account, service: service, sub: period.label),
                            groupLabel: account.displayName,
                            optionLabel: period.displayName,
                            symbol: "a.circle",
                            display: .percent(period.remainingPercent)
                        ))
                    }
                case .speech(let pack):
                    metrics.append(MenuBarMetric(
                        id: metricID(account: account, service: service, sub: pack.title),
                        groupLabel: account.displayName,
                        optionLabel: pack.title,
                        symbol: pack.unit == "小时" ? "waveform" : "mic",
                        display: .percent(pack.remainingPercent)
                    ))
                }
            }
        }
        availableMetrics = metrics
    }

    var currentMetric: MenuBarMetric? {
        let all = availableMetrics
        if let id = selectedMetricID, let m = all.first(where: { $0.id == id }) {
            return m
        }
        return all.first
    }

    var menuBarText: String { currentMetric?.display.menuBarText ?? "--" }
    var menuBarSymbol: String { currentMetric?.symbol ?? "gauge" }

    private func metricID(account: Account, service: Service, sub: String) -> String {
        "\(account.id)/\(service.id)/\(sub)"
    }

    /// 面板展示用账号列表：按设置里账号的顺序排（与 accountConfigs 一致，可拖动调整）。
    var visibleAccounts: [Account] {
        let order = Dictionary(uniqueKeysWithValues: accountConfigs.enumerated().map { ($1.id, $0) })
        return accounts.sorted { a, b in
            (order[a.id] ?? Int.max) < (order[b.id] ?? Int.max)
        }
    }

    /// 拖动重排账号（侧边栏），影响面板显示顺序。
    func moveAccounts(from source: IndexSet, to destination: Int) {
        accountConfigs.move(fromOffsets: source, toOffset: destination)
        AccountStore.save(accountConfigs)
    }

    // MARK: 刷新调度（每源独立定时器 + 休眠/断网感知 + 懒刷新）

    @ObservationIgnored private var lastSuccessAt: [RefreshSource: Date] = [:]
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var networkUp = true
    @ObservationIgnored private var netMonitor: NWPathMonitor?
    @ObservationIgnored private var started = false

    func startAutomaticRefresh() {
        guard !started else { return }
        started = true
        observeSystemEvents()
        startNetworkMonitor()
        refresh()
        for source in RefreshSource.allCases {
            scheduleTimer(for: source)
        }
    }

    private func scheduleTimer(for source: RefreshSource) {
        let seconds = TimeInterval(interval(for: source))
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSource(source) }
        }
        t.tolerance = max(15, seconds * 0.2)
        RunLoop.main.add(t, forMode: .default)
        timers[source] = t
    }

    private func rescheduleTimer(for source: RefreshSource) {
        guard timers[source] != nil else { return }
        timers[source]?.invalidate()
        timers[source] = nil
        scheduleTimer(for: source)
    }

    private func stopAllTimers() {
        for (_, t) in timers { t.invalidate() }
        timers.removeAll()
    }

    // MARK: 系统事件（休眠/唤醒/锁屏）

    private func observeSystemEvents() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pause() }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resume() }
            }
        }
    }

    private func pause() {
        guard !paused else { return }
        paused = true
        stopAllTimers()
    }

    private func resume() {
        guard paused else { return }
        paused = false
        for source in RefreshSource.allCases { scheduleTimer(for: source) }
        if networkUp { refresh() }
    }

    // MARK: 网络监控

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        netMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.setNetwork(up: path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "net.monitor"))
    }

    private func setNetwork(up: Bool) {
        let was = networkUp
        networkUp = up
        if up && !was && !paused { refresh() }
    }

    // MARK: 刷新入口

    /// 全量刷新所有账号所有启用的服务。
    func refresh() {
        refreshSource(.agentPlan)
        refreshSource(.speech)
    }

    /// 打开面板时：只刷已过期的源。
    func refreshIfStale() {
        guard networkUp else { return }
        let now = Date()
        for source in RefreshSource.allCases {
            let limit = TimeInterval(interval(for: source))
            if let last = lastSuccessAt[source], now.timeIntervalSince(last) < limit {
                continue
            }
            refreshSource(source)
        }
    }

    @ObservationIgnored private var refreshing: Set<RefreshSource> = []

    /// 刷新某类服务（跨所有账号）。
    private func refreshSource(_ source: RefreshSource) {
        guard !refreshing.contains(source) else { return }
        guard networkUp else { return }
        refreshing.insert(source)
        isRefreshing = !refreshing.isEmpty
        Task {
            var anyOK = false
            for config in accountConfigs {
                switch source {
                case .agentPlan where config.enableAgentPlan:
                    if await fetchAgentPlan(for: config) { anyOK = true }
                case .speech where !config.speechApps.isEmpty:
                    if await fetchSpeech(for: config) { anyOK = true }
                default:
                    break
                }
            }
            let now = Date()
            lastRefreshAt = now
            if anyOK { lastSuccessAt[source] = now }
            refreshing.remove(source)
            isRefreshing = !refreshing.isEmpty
        }
    }

    /// 刷新单个账号配置的全部启用服务（增删改后调用）。
    private func refreshAccountConfig(_ config: AccountConfig) {
        Task {
            isRefreshing = true
            if config.enableAgentPlan { _ = await fetchAgentPlan(for: config) }
            if !config.speechApps.isEmpty { _ = await fetchSpeech(for: config) }
            // 都没启用则移除展示账号
            if !config.enableAgentPlan && config.speechApps.isEmpty {
                accounts.removeAll { $0.id == config.id }
            }
            lastRefreshAt = Date()
            isRefreshing = false
        }
    }

    // MARK: 取数

    /// 确保拿到该账号的完整账号 ID（用于命名尾号），只查一次。
    private func ensureAccountID(_ config: AccountConfig, ak: String, sk: String) async {
        guard accountFullID_[config.id] == nil else { return }
        if let id = await VolcSigner.fetchAccountID(accessKeyID: ak, secretAccessKey: sk) {
            accountFullID_[config.id] = id
            // 回写配置持久化，下次启动免查
            if let idx = accountConfigs.firstIndex(where: { $0.id == config.id }) {
                accountConfigs[idx].accountFullID = id
                AccountStore.save(accountConfigs)
            }
        }
    }

    private func fetchAgentPlan(for config: AccountConfig) async -> Bool {
        let ak = AccountStore.accessKeyID(for: config.id)
        let sk = AccountStore.secretAccessKey(for: config.id)
        guard !ak.isEmpty, !sk.isEmpty else { return false }
        await ensureAccountID(config, ak: ak, sk: sk)
        let provider = AgentPlanProvider(accessKeyID: ak, secretAccessKey: sk)
        do {
            let plan = try await provider.fetch()
            let service = Service(id: "agent-plan", title: "Agent Plan",
                                  content: .agentPlan(plan), status: .ok,
                                  errorMessage: nil, updatedAt: Date())
            upsertService(config: config, service: service)
            return true
        } catch {
            markServiceError(config: config, serviceID: "agent-plan",
                             serviceTitle: "Agent Plan", agentPlan: true,
                             message: error.localizedDescription)
            return false
        }
    }

    private func fetchSpeech(for config: AccountConfig) async -> Bool {
        let ak = AccountStore.accessKeyID(for: config.id)
        let sk = AccountStore.secretAccessKey(for: config.id)
        guard !ak.isEmpty, !sk.isEmpty, !config.speechApps.isEmpty else { return false }
        await ensureAccountID(config, ak: ak, sk: sk)
        let now = Date()
        var services: [Service] = []
        var anyOK = false
        var lastError: String?
        for app in config.speechApps {
            guard let appID = Int(app.appID), appID > 0 else { continue }
            let provider = SpeechProvider(accessKeyID: ak, secretAccessKey: sk, appID: appID)
            do {
                let packs = try await provider.fetch()
                anyOK = true
                for p in packs {
                    let pack = SpeechPack(title: p.title, purchased: p.purchased, used: p.used,
                                          unit: p.unit, purchasedValue: p.purchasedValue,
                                          usedValue: p.usedValue, expires: p.expires, type: p.type)
                    // 多应用，或用户自定义了备注时，在标题前加应用标识，避免重名
                    let showPrefix = config.speechApps.count > 1 || !app.label.trimmingCharacters(in: .whitespaces).isEmpty
                    let prefix = showPrefix ? "\(app.displayLabel) · " : ""
                    services.append(Service(
                        id: "speech-\(app.id)-\(p.title)",
                        title: "\(prefix)\(p.title)",
                        content: .speech(pack), status: .ok, errorMessage: nil, updatedAt: now))
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        if !services.isEmpty {
            setSpeechServices(config: config, services: services)
            return true
        }
        // 全部应用都没拿到：有错就标错，否则移除
        if let err = lastError {
            markSpeechError(config: config, message: err)
        } else {
            removeSpeechServices(config: config)
        }
        return anyOK
    }

    // MARK: 账号/服务写入

    private func makeAccount(config: AccountConfig, services: [Service]) -> Account {
        let full = accountFullID_[config.id]
        return Account(id: config.id, platform: config.platform.displayName, defaultName: "",
                       idTail: full.map { String($0.suffix(4)) }, fullID: full,
                       alias: config.alias.isEmpty ? nil : config.alias, services: services)
    }

    private func applyMeta(_ i: Int, config: AccountConfig) {
        let full = accountFullID_[config.id]
        accounts[i].platform = config.platform.displayName
        accounts[i].fullID = full
        accounts[i].idTail = full.map { String($0.suffix(4)) }
        accounts[i].alias = config.alias.isEmpty ? nil : config.alias
    }

    /// 插入/更新单个服务（Agent Plan）。
    private func upsertService(config: AccountConfig, service: Service) {
        if let ai = accounts.firstIndex(where: { $0.id == config.id }) {
            if let si = accounts[ai].services.firstIndex(where: { $0.id == service.id }) {
                accounts[ai].services[si] = service
            } else {
                accounts[ai].services.append(service)
            }
            applyMeta(ai, config: config)
        } else {
            accounts.append(makeAccount(config: config, services: [service]))
        }
        sortServices(accountID: config.id)
    }

    /// 整体替换某账号的语音服务（保留 Agent Plan 服务）。
    private func setSpeechServices(config: AccountConfig, services: [Service]) {
        if let ai = accounts.firstIndex(where: { $0.id == config.id }) {
            accounts[ai].services.removeAll { $0.id.hasPrefix("speech-") }
            accounts[ai].services.append(contentsOf: services)
            applyMeta(ai, config: config)
            sortServices(accountID: config.id)
        } else {
            accounts.append(makeAccount(config: config, services: services))
        }
    }

    private func removeSpeechServices(config: AccountConfig) {
        guard let ai = accounts.firstIndex(where: { $0.id == config.id }) else { return }
        accounts[ai].services.removeAll { $0.id.hasPrefix("speech-") }
        if accounts[ai].services.isEmpty { accounts.remove(at: ai) }
    }

    /// 保证服务顺序稳定：Agent Plan 在前，语音在后。
    private func sortServices(accountID: String) {
        guard let ai = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[ai].services.sort { a, b in
            func rank(_ id: String) -> Int { id == "agent-plan" ? 0 : 1 }
            return rank(a.id) < rank(b.id)
        }
    }

    private func markServiceError(config: AccountConfig, serviceID: String,
                                  serviceTitle: String, agentPlan: Bool, message: String) {
        if let ai = accounts.firstIndex(where: { $0.id == config.id }),
           let si = accounts[ai].services.firstIndex(where: { $0.id == serviceID }) {
            accounts[ai].services[si].status = .error
            accounts[ai].services[si].errorMessage = message
        } else {
            let content: ServiceContent = agentPlan
                ? .agentPlan(AgentPlan(tier: "", edition: "", unit: "AFP", periods: []))
                : .speech(SpeechPack(title: serviceTitle, purchased: "", used: "", unit: "",
                                     purchasedValue: 0, usedValue: 0, expires: "", type: ""))
            let service = Service(id: serviceID, title: serviceTitle, content: content,
                                  status: .error, errorMessage: message, updatedAt: nil)
            upsertService(config: config, service: service)
        }
    }

    private func markSpeechError(config: AccountConfig, message: String) {
        if let ai = accounts.firstIndex(where: { $0.id == config.id }),
           accounts[ai].services.contains(where: { $0.id.hasPrefix("speech-") }) {
            for si in accounts[ai].services.indices where accounts[ai].services[si].id.hasPrefix("speech-") {
                accounts[ai].services[si].status = .error
                accounts[ai].services[si].errorMessage = message
            }
        } else {
            markServiceError(config: config, serviceID: "speech-placeholder",
                             serviceTitle: "语音服务", agentPlan: false, message: message)
        }
    }
}
