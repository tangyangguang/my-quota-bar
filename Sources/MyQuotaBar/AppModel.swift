import AppKit
import Foundation
import Network
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var accounts: [Account] = [] {
        didSet { rebuildMetrics() }
    }
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

    /// Agent Plan 对应的 arkcli profile 名。可在设置里选；未选时启动自动发现。
    private(set) var arkPlanProfile: String = AppSettings.agentPlanProfile ?? ""
    /// 本机可用的 arkcli profile 列表（设置里下拉选择）。
    private(set) var arkProfiles: [ArkProfile] = []

    private let speechAccountID = "speech-account-b"
    @ObservationIgnored private var speechAccountIDFetched = false
    private let platformName = "火山引擎"

    // MARK: 服务可见性（设置里可勾选显示/隐藏）

    /// 隐藏的服务 ID。隐藏后面板不显示、也不进菜单栏可选项。
    var hiddenServiceIDs: Set<String> = AppSettings.hiddenServiceIDs {
        didSet {
            AppSettings.hiddenServiceIDs = hiddenServiceIDs
            rebuildMetrics()
        }
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
        selectedMetricID = AppSettings.selectedMetricID
    }

    /// 选定 Agent Plan profile（设置里下拉），并立即刷新。
    func selectAgentPlanProfile(_ name: String) {
        guard name != arkPlanProfile else { return }
        // 清掉旧 profile 对应账号（避免残留）。
        if !arkPlanProfile.isEmpty {
            accounts.removeAll { $0.id == arkPlanProfile }
        }
        arkPlanProfile = name
        AppSettings.agentPlanProfile = name
        refreshSource(.agentPlan)
    }

    /// 启动时发现本机 profile；若用户未选，自动选第一个 agent-plan 类型的。
    private func discoverProfilesIfNeeded() async {
        arkProfiles = await ArkProfileLister.list()
        if arkPlanProfile.isEmpty {
            if let auto = arkProfiles.first(where: { $0.type == "agent-plan" }) ?? arkProfiles.first {
                arkPlanProfile = auto.name
                AppSettings.agentPlanProfile = auto.name
            }
        }
    }

    // MARK: 菜单栏文本

    /// 所有可选指标（拍平）。缓存起来，仅在账号/可见性变化时重建，
    /// 避免 menuBarText/currentMetric 每次渲染都遍历重算。
    private(set) var availableMetrics: [MenuBarMetric] = []

    /// 重建指标缓存（数据或隐藏集变化时调用）。
    private func rebuildMetrics() {
        var metrics: [MenuBarMetric] = []
        for account in accounts {
            for service in account.services {
                if !isServiceVisible(accountID: account.id, serviceID: service.id) { continue }
                switch service.content {
                case .agentPlan(let plan):
                    for period in plan.periods {
                        metrics.append(MenuBarMetric(
                            id: metricID(account: account, service: service, sub: period.label),
                            groupLabel: account.displayName,
                            optionLabel: period.displayName,
                            symbol: "a.circle",   // Agent Plan 用 a 字图标，窄
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

    // MARK: 刷新调度（每源独立定时器 + 休眠/断网感知 + 懒刷新）

    /// 各源最后一次“成功”刷新时间（用于懒刷新判断）。
    @ObservationIgnored private var lastSuccessAt: [RefreshSource: Date] = [:]
    /// 是否已暂停（休眠/锁屏/断网）。暂停时定时器不发请求。
    @ObservationIgnored private var paused = false
    /// 网络是否可用。
    @ObservationIgnored private var networkUp = true
    @ObservationIgnored private var netMonitor: NWPathMonitor?
    @ObservationIgnored private var started = false

    func startAutomaticRefresh() {
        guard !started else { return }
        started = true
        observeSystemEvents()
        startNetworkMonitor()
        Task {
            await discoverProfilesIfNeeded()
            refresh()   // 发现 profile 后先全量拉一次
        }
        for source in RefreshSource.allCases {
            scheduleTimer(for: source)
        }
    }

    private func scheduleTimer(for source: RefreshSource) {
        let seconds = TimeInterval(interval(for: source))
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSource(source) }
        }
        // 允许系统批量合并定时器唤醒（降低 CPU 唤醒次数、省电）。
        // 数据上游本就延迟 5–30 分钟，晚几十秒无影响。
        t.tolerance = max(15, seconds * 0.2)
        // 用默认 mode（非 .common）：后台刷新无需在拖拽/滚动时抢跑。
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
        // 系统休眠 / 显示器息屏 / 锁屏 → 暂停（不再轮询）
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pause() }
            }
        }
        // 唤醒 / 屏幕点亮 → 恢复，并立即补刷一次
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
        if networkUp { refresh() }   // 唤醒后立即补刷，你看到的是新的
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
        if up && !was && !paused { refresh() }   // 网络恢复 → 补刷一次
    }

    // MARK: 刷新入口

    /// 全量刷新（手动“刷新”按钮 / 启动 / 唤醒 / 网络恢复）。
    func refresh() {
        refreshSource(.agentPlan)
        refreshSource(.speech)
    }

    /// 打开面板时调用：只刷“已过期”的源（距上次成功超过间隔），没过期则用缓存不发请求。
    func refreshIfStale() {
        guard networkUp else { return }
        let now = Date()
        for source in RefreshSource.allCases {
            let limit = TimeInterval(interval(for: source))
            if let last = lastSuccessAt[source], now.timeIntervalSince(last) < limit {
                continue   // 还新鲜，不刷
            }
            refreshSource(source)
        }
    }

    @ObservationIgnored private var refreshing: Set<RefreshSource> = []

    /// 刷新单个源（定时器回调 / 单独触发）。
    private func refreshSource(_ source: RefreshSource) {
        guard !refreshing.contains(source) else { return }
        guard networkUp else { return }   // 断网不发无用请求
        refreshing.insert(source)
        isRefreshing = !refreshing.isEmpty
        Task {
            let ok: Bool
            switch source {
            case .agentPlan: ok = await refreshAgentPlan()
            case .speech: ok = await refreshSpeech()
            }
            let now = Date()
            lastRefreshAt = now
            if ok { lastSuccessAt[source] = now }
            refreshing.remove(source)
            isRefreshing = !refreshing.isEmpty
        }
    }

    private func refreshAgentPlan() async -> Bool {
        guard !arkPlanProfile.isEmpty else { return false }   // 未选 profile 则不拉
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
            upsertAccount(id: arkPlanProfile,
                          platform: platformName,
                          defaultName: plan.userName?.trimmingCharacters(in: .whitespaces) ?? "",
                          fullID: plan.accountID,
                          service: service)
            return true
        } catch {
            // 保留上一次有效值，仅标记 error。
            markServiceError(accountID: arkPlanProfile, serviceID: "agent-plan",
                             serviceTitle: "Agent Plan",
                             message: error.localizedDescription)
            return false
        }
    }

    // MARK: 账号B · 语音服务

    /// 语音账号自动获取到的信息（用于命名）。
    @ObservationIgnored private var speechFullID: String?

    /// 清除语音账号（用户在设置里清除密钥时）。
    func clearSpeechAccount() {
        accounts.removeAll { $0.id == speechAccountID }
        speechAccountIDFetched = false
        speechFullID = nil
    }

    private func refreshSpeech() async -> Bool {
        // 未配置 AK/SK 则不尝试（避免报错刷屏）。
        guard SpeechCredentials.isConfigured else { return false }
        let ak = SpeechCredentials.accessKeyID
        let sk = SpeechCredentials.secretAccessKey
        let appID = Int(SpeechCredentials.appID) ?? 0
        let now = Date()

        let provider = SpeechProvider(accessKeyID: ak, secretAccessKey: sk, appID: appID)
        do {
            // 首次拉取账号 ID，用于命名（与 Agent Plan 对齐）。
            if !speechAccountIDFetched {
                speechFullID = await provider.fetchAccountID()
                speechAccountIDFetched = true
            }
            let packs = try await provider.fetch()
            // 层级与 Agent Plan 对齐：每个 pack 当作一个独立服务挂在语音账号下。
            // 成功时重建该账号的服务列表（清掉旧的 error 占位服务）。
            let services = packs.map { p -> Service in
                let pack = SpeechPack(title: p.title, purchased: p.purchased, used: p.used,
                                      unit: p.unit, purchasedValue: p.purchasedValue,
                                      usedValue: p.usedValue, expires: p.expires, type: p.type)
                return Service(
                    id: "speech-\(p.title)", title: p.title,
                    content: .speech(pack), status: .ok, errorMessage: nil, updatedAt: now
                )
            }
            if services.isEmpty {
                // 配了密钥但没查到资源包：不报错，只移除该账号。
                accounts.removeAll { $0.id == speechAccountID }
            } else {
                setAccountServices(id: speechAccountID, platform: platformName,
                                   defaultName: "语音账号", fullID: speechFullID,
                                   services: services)
            }
            return true
        } catch {
            markSpeechError(message: error.localizedDescription)
            return false
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
            upsertAccount(id: speechAccountID, platform: platformName,
                          defaultName: "语音账号", fullID: speechFullID, service: service)
        }
    }

    // MARK: 账号别名

    /// 设置账号别名（nil / 空 = 恢复默认用户名）。
    func setAlias(_ alias: String?, for accountID: String) {
        AppSettings.setAlias(alias, for: accountID)
        if let ai = accounts.firstIndex(where: { $0.id == accountID }) {
            accounts[ai].alias = (alias?.isEmpty == false) ? alias : nil
        }
    }

    // MARK: 账号/服务写入

    /// 构造账号元数据（平台/默认名/ID 尾号/完整 ID/别名）并写入字段。
    private func applyMeta(_ i: Int, platform: String, defaultName: String, fullID: String?) {
        accounts[i].platform = platform
        accounts[i].defaultName = defaultName
        accounts[i].fullID = fullID
        accounts[i].idTail = fullID.map { String($0.suffix(4)) }
        accounts[i].alias = AppSettings.alias(for: accounts[i].id)
    }

    private func makeAccount(id: String, platform: String, defaultName: String,
                             fullID: String?, services: [Service]) -> Account {
        Account(id: id, platform: platform, defaultName: defaultName,
                idTail: fullID.map { String($0.suffix(4)) }, fullID: fullID,
                alias: AppSettings.alias(for: id), services: services)
    }

    /// 整个替换一个账号的服务列表（用于刷新成功时重建，清掉旧残留）。
    private func setAccountServices(id: String, platform: String, defaultName: String,
                                    fullID: String?, services: [Service]) {
        if let ai = accounts.firstIndex(where: { $0.id == id }) {
            accounts[ai].services = services
            applyMeta(ai, platform: platform, defaultName: defaultName, fullID: fullID)
        } else {
            accounts.append(makeAccount(id: id, platform: platform, defaultName: defaultName,
                                        fullID: fullID, services: services))
        }
    }

    private func upsertAccount(id: String, platform: String, defaultName: String,
                              fullID: String?, service: Service) {
        if let ai = accounts.firstIndex(where: { $0.id == id }) {
            if let si = accounts[ai].services.firstIndex(where: { $0.id == service.id }) {
                accounts[ai].services[si] = service
            } else {
                accounts[ai].services.append(service)
            }
            applyMeta(ai, platform: platform, defaultName: defaultName, fullID: fullID)
        } else {
            accounts.append(makeAccount(id: id, platform: platform, defaultName: defaultName,
                                        fullID: fullID, services: [service]))
        }
    }

    private func markServiceError(accountID: String, serviceID: String,
                                  serviceTitle: String, message: String) {
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
            upsertAccount(id: accountID, platform: platformName, defaultName: "",
                          fullID: nil, service: service)
        }
    }
}
