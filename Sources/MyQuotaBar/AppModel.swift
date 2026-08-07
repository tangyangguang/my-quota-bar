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
    /// 最近一次成功刷新时间（失败尝试不会伪装成“刚刚更新”）。
    private(set) var lastRefreshAt: Date?
    private(set) var configurationWarning: String?
    private(set) var persistenceError: String?

    /// 用户选择在菜单栏常驻显示的指标 ID。
    var selectedMetricID: String? {
        didSet { AppSettings.selectedMetricID = selectedMetricID }
    }

    @ObservationIgnored private var schedulerTimer: Timer?
    @ObservationIgnored private let requestGate = AsyncPermitGate(limit: 4)
    /// 配置代数：账号修改/删除时递增，旧网络请求返回后必须丢弃。
    @ObservationIgnored private var accountRevisions: [String: Int] = [:]
    /// 账号 ID -> 该账号完整账号 ID（STS 查得，用于命名尾号）。
    @ObservationIgnored private var accountFullID_: [String: String] = [:]

    /// 刷新源（按服务类型分类，用于独立配置刷新间隔）。
    enum RefreshSource: String, CaseIterable, Sendable {
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
        nextAttemptAt[source] = Date().addingTimeInterval(TimeInterval(seconds))
        scheduleNextRefresh()
    }

    init() {
        selectedMetricID = AppSettings.selectedMetricID
        for source in RefreshSource.allCases {
            refreshIntervals[source.rawValue] = AppSettings.refreshInterval(for: source.rawValue)
        }
        accountConfigs = AccountStore.load()
        configurationWarning = AccountStore.lastLoadWarning
        for c in accountConfigs {
            if let full = c.accountFullID { accountFullID_[c.id] = full }
        }
    }

    // MARK: 账号配置 CRUD（设置窗口调用）

    /// 测试一对 AK/SK：验证身份并拿回账号信息。返回 (成功, 身份信息或错误描述)。
    func testCredentials(platform: Platform = .volcengine, ak: String, sk: String)
        async -> (ok: Bool, identity: PlatformIdentity?, message: String) {
        let a = ak.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = sk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !s.isEmpty else { return (false, nil, "请先填写完整凭证") }
        guard let adapter = PlatformRegistry.adapter(for: platform) else {
            return (false, nil, "当前版本暂不支持平台：\(platform.rawValue)")
        }
        do {
            let identity = try await adapter.testIdentity(credentials: [
                "accessKeyID": a,
                "secretAccessKey": s
            ])
            return (true, identity, "连接成功，账号 ID：\(identity.accountID)")
        } catch {
            return (false, nil, "连接失败：\(error.localizedDescription)")
        }
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
                    accountFullID: String?, enableAgentPlan: Bool, speechApps: [SpeechApp]) throws -> String {
        let config = AccountConfig(platform: platform, alias: alias, accountFullID: accountFullID,
                                   enableAgentPlan: enableAgentPlan, speechApps: speechApps)
        try AccountStore.setCredentials(ak: ak, sk: sk, for: config.id)
        let updated = accountConfigs + [config]
        do {
            try AccountStore.save(updated)
        } catch {
            try? AccountStore.deleteCredentials(for: config.id)
            throw error
        }
        persistenceError = nil
        configurationWarning = nil
        accountConfigs = updated
        accountRevisions[config.id] = 0
        if let full = accountFullID { accountFullID_[config.id] = full }
        refreshAccountConfig(config)
        return config.id
    }

    /// 更新已有账号。ak/sk 传空表示不改动原凭证。
    func updateAccount(id: String, alias: String, ak: String?, sk: String?, accountFullID: String?,
                       enableAgentPlan: Bool, enableSpeech: Bool, speechApps: [SpeechApp]) throws {
        guard let idx = accountConfigs.firstIndex(where: { $0.id == id }) else { return }
        var updated = accountConfigs
        updated[idx].alias = alias
        updated[idx].enableAgentPlan = enableAgentPlan
        updated[idx].enableSpeech = enableSpeech
        updated[idx].speechApps = speechApps
        if let full = accountFullID { updated[idx].accountFullID = full }
        if let ak = ak, let sk = sk {
            try AccountStore.setCredentials(ak: ak, sk: sk, for: id)
        }
        try AccountStore.save(updated)
        persistenceError = nil
        configurationWarning = nil
        accountConfigs = updated
        bumpRevision(for: id)
        if let full = updated[idx].accountFullID { accountFullID_[id] = full }
        // 删掉已不存在的展示服务（先清空该账号，重新拉）
        accounts.removeAll { $0.id == id }
        refreshAccountConfig(updated[idx])
    }

    /// 删除账号：清凭证、清配置、从面板移除。
    func removeAccount(id: String) throws {
        let updated = accountConfigs.filter { $0.id != id }
        try AccountStore.save(updated)
        accountConfigs = updated
        bumpRevision(for: id)
        accounts.removeAll { $0.id == id }
        accountFullID_[id] = nil
        persistenceError = nil
        configurationWarning = nil
        try AccountStore.deleteCredentials(for: id)
    }

    func credentials(for id: String) -> (ak: String, sk: String) {
        (AccountStore.accessKeyID(for: id), AccountStore.secretAccessKey(for: id))
    }

    private func bumpRevision(for id: String) {
        accountRevisions[id, default: 0] += 1
    }

    private func isCurrent(accountID: String, revision: Int) -> Bool {
        accountRevisions[accountID, default: 0] == revision
            && accountConfigs.contains { $0.id == accountID }
    }

    // MARK: 菜单栏文本

    /// 所有可选指标（拍平）。缓存，仅数据变化时重建。
    private(set) var availableMetrics: [MenuBarMetric] = []

    private func rebuildMetrics() {
        var metrics: [MenuBarMetric] = []
        for account in visibleAccounts {
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

    /// 公开：供面板视图构造 metric id（用于"置顶到菜单栏"快捷方式）。
    func metricID(account: Account, service: Service, sub: String) -> String {
        "\(account.id)/\(service.id)/\(sub)"
    }

    /// 面板展示用账号列表：按设置里账号的顺序排（与 accountConfigs 一致，可拖动调整）。
    var visibleAccounts: [Account] {
        let order = Dictionary(uniqueKeysWithValues: accountConfigs.enumerated().map { ($1.id, $0) })
        return accounts.sorted { a, b in
            (order[a.id] ?? Int.max) < (order[b.id] ?? Int.max)
        }
    }

    /// 在同一平台分组内重排账号，影响面板显示顺序。
    func moveAccounts(in platform: Platform, from source: IndexSet, to destination: Int) {
        var group = accountConfigs.filter { $0.platform == platform }
        group.move(fromOffsets: source, toOffset: destination)
        var iterator = group.makeIterator()
        let updated = accountConfigs.map { config in
            config.platform == platform ? (iterator.next() ?? config) : config
        }
        persistReorderedAccounts(updated)
    }

    /// 供上移/下移菜单使用的全局移动（当前 UI 会限制在同平台语境）。
    func moveAccounts(from source: IndexSet, to destination: Int) {
        var updated = accountConfigs
        updated.move(fromOffsets: source, toOffset: destination)
        persistReorderedAccounts(updated)
    }

    private func persistReorderedAccounts(_ updated: [AccountConfig]) {
        do {
            try AccountStore.save(updated)
            accountConfigs = updated
            rebuildMetrics()
            persistenceError = nil
            configurationWarning = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    // MARK: 刷新调度（每源独立定时器 + 休眠/断网感知 + 懒刷新）

    @ObservationIgnored private var lastSuccessAt: [RefreshSource: Date] = [:]
    @ObservationIgnored private var nextAttemptAt: [RefreshSource: Date] = [:]
    @ObservationIgnored private var failureCount: [RefreshSource: Int] = [:]
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
    }

    /// 全 App 只有一个非重复 Timer，唤醒最近到期的数据源；账号数量增加不会增加 Timer 数。
    private func scheduleNextRefresh() {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
        guard started, !paused, networkUp,
              refreshing.isEmpty, accountRefreshOperations.isEmpty else { return }

        let now = Date()
        let next = RefreshSource.allCases.map { source -> Date in
            if let date = nextAttemptAt[source] { return date }
            if let success = lastSuccessAt[source] {
                return success.addingTimeInterval(TimeInterval(interval(for: source)))
            }
            return now.addingTimeInterval(TimeInterval(interval(for: source)))
        }.min() ?? now.addingTimeInterval(180)
        let delay = max(1, next.timeIntervalSince(now))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshDueSources() }
        }
        timer.tolerance = max(15, delay * 0.2)
        RunLoop.main.add(timer, forMode: .default)
        schedulerTimer = timer
    }

    private func refreshDueSources() {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
        let now = Date()
        var startedAny = false
        for source in RefreshSource.allCases {
            let due = nextAttemptAt[source]
                ?? lastSuccessAt[source]?.addingTimeInterval(TimeInterval(interval(for: source)))
                ?? now
            if due <= now {
                startedAny = true
                refreshSource(source)
            }
        }
        if !startedAny { scheduleNextRefresh() }
    }

    private func stopScheduler() {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
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
        stopScheduler()
    }

    private func resume() {
        guard paused else { return }
        paused = false
        if networkUp { refreshIfStale() }
        scheduleNextRefresh()
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
        if up && !was && !paused {
            refreshIfStale()
            scheduleNextRefresh()
        } else if !up {
            stopScheduler()
        }
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
            if let retry = nextAttemptAt[source], retry > now { continue }
            let limit = TimeInterval(interval(for: source))
            if let last = lastSuccessAt[source], now.timeIntervalSince(last) < limit { continue }
            refreshSource(source)
        }
    }

    @ObservationIgnored private var refreshing: Set<RefreshSource> = []
    @ObservationIgnored private var accountRefreshOperations: Set<UUID> = []

    private func updateRefreshingState() {
        isRefreshing = !refreshing.isEmpty || !accountRefreshOperations.isEmpty
    }

    /// 刷新某类服务（跨所有账号）。
    private func refreshSource(_ source: RefreshSource) {
        guard !refreshing.contains(source) else { return }
        guard networkUp else { return }
        refreshing.insert(source)
        updateRefreshingState()
        Task {
            let jobs: [(AccountConfig, Int)] = accountConfigs.compactMap { config in
                guard config.platform == .volcengine else { return nil }
                switch source {
                case .agentPlan where config.enableAgentPlan:
                    return (config, accountRevisions[config.id, default: 0])
                case .speech where config.enableSpeech && !config.speechApps.isEmpty:
                    return (config, accountRevisions[config.id, default: 0])
                default:
                    return nil
                }
            }

            var anyOK = false
            await withTaskGroup(of: Bool.self) { group in
                for (config, revision) in jobs {
                    group.addTask { [requestGate] in
                        await requestGate.acquire()
                        let ok: Bool
                        switch source {
                        case .agentPlan:
                            ok = await self.fetchAgentPlan(for: config, revision: revision)
                        case .speech:
                            ok = await self.fetchSpeech(for: config, revision: revision)
                        }
                        await requestGate.release()
                        return ok
                    }
                }
                for await ok in group where ok { anyOK = true }
            }

            let now = Date()
            if jobs.isEmpty {
                failureCount[source] = 0
                nextAttemptAt[source] = now.addingTimeInterval(TimeInterval(interval(for: source)))
            } else if anyOK {
                failureCount[source] = 0
                lastSuccessAt[source] = now
                lastRefreshAt = now
                nextAttemptAt[source] = now.addingTimeInterval(TimeInterval(interval(for: source)))
            } else {
                let failures = failureCount[source, default: 0] + 1
                failureCount[source] = failures
                let exponential = 60.0 * pow(2.0, Double(min(failures - 1, 4)))
                let backoff = min(TimeInterval(interval(for: source)), exponential)
                nextAttemptAt[source] = now.addingTimeInterval(backoff)
            }
            refreshing.remove(source)
            updateRefreshingState()
            scheduleNextRefresh()
        }
    }

    /// 刷新单个账号配置的全部启用服务（增删改后调用）。
    private func refreshAccountConfig(_ config: AccountConfig) {
        let revision = accountRevisions[config.id, default: 0]
        let operationID = UUID()
        accountRefreshOperations.insert(operationID)
        updateRefreshingState()
        Task {
            defer {
                accountRefreshOperations.remove(operationID)
                updateRefreshingState()
                scheduleNextRefresh()
            }
            guard config.platform == .volcengine else {
                accounts.removeAll { $0.id == config.id }
                return
            }
            var anyOK = false
            if config.enableAgentPlan {
                anyOK = await fetchAgentPlan(for: config, revision: revision) || anyOK
            }
            if config.enableSpeech && !config.speechApps.isEmpty {
                anyOK = await fetchSpeech(for: config, revision: revision) || anyOK
            }
            guard isCurrent(accountID: config.id, revision: revision) else { return }
            // 都没启用则移除展示账号
            if !config.enableAgentPlan && (!config.enableSpeech || config.speechApps.isEmpty) {
                accounts.removeAll { $0.id == config.id }
            }
            if anyOK { lastRefreshAt = Date() }
        }
    }

    // MARK: 取数

    /// 确保拿到该账号的完整账号 ID（用于命名尾号），只查一次。
    private func ensureAccountID(_ config: AccountConfig, ak: String, sk: String,
                                 revision: Int) async {
        guard accountFullID_[config.id] == nil else { return }
        if let id = await VolcSigner.fetchAccountID(accessKeyID: ak, secretAccessKey: sk) {
            guard isCurrent(accountID: config.id, revision: revision) else { return }
            accountFullID_[config.id] = id
            // 回写配置持久化，下次启动免查
            if let idx = accountConfigs.firstIndex(where: { $0.id == config.id }) {
                accountConfigs[idx].accountFullID = id
                do {
                    try AccountStore.save(accountConfigs)
                    persistenceError = nil
                } catch {
                    persistenceError = error.localizedDescription
                }
            }
        }
    }

    private func fetchAgentPlan(for config: AccountConfig, revision: Int) async -> Bool {
        guard config.platform == .volcengine else { return false }
        let ak = AccountStore.accessKeyID(for: config.id)
        let sk = AccountStore.secretAccessKey(for: config.id)
        guard !ak.isEmpty, !sk.isEmpty else { return false }
        await ensureAccountID(config, ak: ak, sk: sk, revision: revision)
        guard isCurrent(accountID: config.id, revision: revision) else { return false }
        let provider = AgentPlanProvider(accessKeyID: ak, secretAccessKey: sk)
        do {
            let plan = try await provider.fetch()
            guard isCurrent(accountID: config.id, revision: revision) else { return false }
            let service = Service(id: "agent-plan", title: "Agent Plan",
                                  content: .agentPlan(plan), status: .ok,
                                  errorMessage: nil, updatedAt: Date())
            upsertService(config: config, service: service)
            return true
        } catch {
            guard isCurrent(accountID: config.id, revision: revision) else { return false }
            markServiceError(config: config, serviceID: "agent-plan",
                             serviceTitle: "Agent Plan", agentPlan: true,
                             message: error.localizedDescription)
            return false
        }
    }

    private func fetchSpeech(for config: AccountConfig, revision: Int) async -> Bool {
        guard config.platform == .volcengine else { return false }
        let ak = AccountStore.accessKeyID(for: config.id)
        let sk = AccountStore.secretAccessKey(for: config.id)
        guard !ak.isEmpty, !sk.isEmpty, config.enableSpeech, !config.speechApps.isEmpty else { return false }
        await ensureAccountID(config, ak: ak, sk: sk, revision: revision)
        guard isCurrent(accountID: config.id, revision: revision) else { return false }
        let now = Date()
        let previous = accounts.first(where: { $0.id == config.id })?.services
            .filter { $0.id.hasPrefix("speech-") } ?? []
        var services: [Service] = []
        var anyOK = false

        for app in config.speechApps {
            guard let appID = Int(app.appID), appID > 0 else { continue }
            let provider = SpeechProvider(accessKeyID: ak, secretAccessKey: sk, appID: appID)
            let outcome = await provider.fetchOutcome()
            // 只要至少一个分项请求未报错，就算本应用成功联系到服务端。
            if outcome.errors.count < 2 { anyOK = true }

            let showPrefix = config.speechApps.count > 1
                || !app.label.trimmingCharacters(in: .whitespaces).isEmpty
            let prefix = showPrefix ? "\(app.displayLabel) · " : ""

            for p in outcome.packs {
                let pack = SpeechPack(title: p.title, purchased: p.purchased, used: p.used,
                                      unit: p.unit, purchasedValue: p.purchasedValue,
                                      usedValue: p.usedValue, expires: p.expires, type: p.type)
                services.append(Service(
                    id: "speech-\(app.id)-\(p.instanceID)",
                    title: "\(prefix)\(p.title)",
                    content: .speech(pack), status: .ok, errorMessage: nil, updatedAt: now))
            }

            // 分项失败时保留该分项上一次成功值，只标记错误；没有旧值才放错误占位卡。
            for (title, message) in outcome.errors {
                let oldMatches = previous.filter { service in
                    guard service.id.hasPrefix("speech-\(app.id)-"),
                          case .speech(let pack) = service.content else { return false }
                    return pack.title == title
                }
                if oldMatches.isEmpty {
                    let empty = SpeechPack(title: title, purchased: "", used: "", unit: "",
                                           purchasedValue: 0, usedValue: 0, expires: "", type: "")
                    services.append(Service(id: "speech-\(app.id)-error-\(title)",
                                            title: "\(prefix)\(title)", content: .speech(empty),
                                            status: .error, errorMessage: message, updatedAt: nil))
                } else {
                    for var old in oldMatches {
                        old.title = "\(prefix)\(title)"
                        old.status = .error
                        old.errorMessage = message
                        services.append(old)
                    }
                }
            }
        }
        guard isCurrent(accountID: config.id, revision: revision) else { return false }
        if !services.isEmpty {
            setSpeechServices(config: config, services: services)
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

}

/// 全局网络并发闸门。避免多账号完全串行，也避免无限并发打爆接口。
private actor AsyncPermitGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = max(1, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
