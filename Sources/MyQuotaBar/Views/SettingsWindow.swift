import SwiftUI

/// 独立设置窗口：账号管理（增删改）+ 显示设置。
struct SettingsWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            AccountsTab(model: model)
                .tabItem { Label("账号", systemImage: "person.2") }
            DisplayTab(model: model)
                .tabItem { Label("显示", systemImage: "menubar.rectangle") }
        }
        .frame(width: 720, height: 560)
    }
}

// MARK: - 账号 Tab：左边栏账号列表（主）+ 右侧详情（从）—— macOS 经典主从布局

struct AccountsTab: View {
    @Bindable var model: AppModel
    @State private var selectedID: String?
    @State private var addingNew = false
    @State private var deleteTarget: AccountConfig?

    private var selected: AccountConfig? {
        model.accountConfigs.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .sheet(isPresented: $addingNew) {
            AddAccountSheet(model: model) { newID in selectedID = newID }
        }
        .confirmationDialog(
            "确定删除该账号？",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { target in
            Button("删除账号", role: .destructive) {
                model.removeAccount(id: target.id)
                if selectedID == target.id { selectedID = nil }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { target in
            Text("将从钥匙串删除该账号的密钥，并从面板移除「\(target.alias.isEmpty ? "未命名账号" : target.alias)」的所有服务。此操作不可撤销。")
        }
        .onAppear {
            if selectedID == nil { selectedID = model.accountConfigs.first?.id }
        }
    }

    // 左边栏：账号列表 + 底部 +/− 工具栏
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(model.accountConfigs) { config in
                    AccountRow(config: config).tag(config.id)
                }
                .onMove { model.moveAccounts(from: $0, to: $1) }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 2) {
                Button { addingNew = true } label: {
                    Image(systemName: "plus").frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .help("添加账号")

                Button {
                    if let sel = selected { deleteTarget = sel }
                } label: {
                    Image(systemName: "minus").frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(selected == nil)
                .help("删除选中账号")

                Spacer()
                if model.accountConfigs.count > 1 {
                    Text("拖动可排序")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .frame(width: 190)
    }

    // 右侧详情：选中账号则显示编辑器，否则空态
    @ViewBuilder
    private var detail: some View {
        if let config = selected {
            AccountDetailView(model: model, account: config)
                .id(config.id)   // 换账号时重建，重新 load
        } else {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 40)).foregroundStyle(.secondary)
                Text(model.accountConfigs.isEmpty ? "还没有账号" : "选择左侧账号进行管理")
                    .font(.title3)
                if model.accountConfigs.isEmpty {
                    Text("点左下角「+」添加账号：填入 AK/SK 测试连接即可。\n添加后在这里配置 Agent Plan、语音等服务。\n无需安装任何命令行工具。")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 账号列表里的一行（左边栏）。
struct AccountRow: View {
    let config: AccountConfig

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.alias.isEmpty ? "未命名账号" : config.alias)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(serviceSummary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var serviceSummary: String {
        var parts: [String] = []
        if config.enableAgentPlan { parts.append("Agent Plan") }
        if !config.speechApps.isEmpty { parts.append("语音 ×\(config.speechApps.count)") }
        return parts.isEmpty ? "未配置服务" : parts.joined(separator: " · ")
    }
}

// MARK: - 添加账号弹窗（只管账号本身：平台 + 密钥 + 名称；测试可选，不挡保存）

struct AddAccountSheet: View {
    @Bindable var model: AppModel
    var onAdded: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    @State private var platform: Platform = .volcengine
    @State private var ak = ""
    @State private var sk = ""
    @State private var credState = TestState.idle
    @State private var accountFullID: String?
    @State private var fetchedName: String?
    @State private var alias = ""

    private var canSave: Bool {
        !ak.trimmingCharacters(in: .whitespaces).isEmpty
            && !sk.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("添加账号").font(.headline).padding(.top, 16)

            VStack(alignment: .leading, spacing: 14) {
                GroupBox {
                    Picker("平台", selection: $platform) {
                        ForEach(Platform.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                } label: {
                    Label("平台", systemImage: "cloud")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        RevealableField(title: "Access Key ID", text: $ak)
                            .onChange(of: ak) { resetCred() }
                        RevealableField(title: "Secret Access Key", text: $sk)
                            .onChange(of: sk) { resetCred() }
                        HStack(spacing: 8) {
                            Button {
                                Task { await testCredentials() }
                            } label: {
                                if case .testing = credState {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("测试连接")
                                }
                            }
                            .disabled(!canSave || credState.isTesting)
                            stateLabel(credState)
                        }
                        Text("在火山引擎控制台「访问控制 → API 访问密钥」创建。加密存入 macOS 钥匙串，纯本地。建议先测试再保存。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } label: {
                    Label("火山引擎密钥（AK / SK）", systemImage: "key")
                }

                GroupBox {
                    HStack(spacing: 6) {
                        TextField("账户名称（显示在面板上，可留空）", text: $alias)
                            .textFieldStyle(.roundedBorder)
                        if let name = fetchedName, !name.isEmpty, alias != name {
                            Button("重置") { alias = name }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("恢复为获取到的真实名称：\(name)")
                        }
                    }
                } label: {
                    Label("账户名称", systemImage: "tag")
                }
            }
            .padding(16)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加账号") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 460, height: 400)
    }

    @ViewBuilder
    private func stateLabel(_ state: TestState) -> some View {
        switch state {
        case .idle, .testing: EmptyView()
        case .success(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).lineLimit(2)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func resetCred() {
        credState = .idle
        accountFullID = nil
        fetchedName = nil
    }

    private func testCredentials() async {
        credState = .testing
        let r = await model.testCredentials(ak: ak, sk: sk)
        if r.ok, let identity = r.identity {
            accountFullID = identity.accountID
            fetchedName = identity.friendlyName
            credState = .success(r.message)
            if alias.trimmingCharacters(in: .whitespaces).isEmpty {
                alias = identity.friendlyName
            }
        } else {
            credState = .failure(r.message)
        }
    }

    private func save() {
        let newID = model.addAccount(
            platform: platform,
            alias: alias.trimmingCharacters(in: .whitespacesAndNewlines),
            ak: ak.trimmingCharacters(in: .whitespaces),
            sk: sk.trimmingCharacters(in: .whitespaces),
            accountFullID: accountFullID,
            enableAgentPlan: false, speechApps: [])
        onAdded(newID)
        dismiss()
    }
}

// MARK: - 账号详情（右侧）：上「账号信息」+ 下「服务」，两区块独立

struct AccountDetailView: View {
    @Bindable var model: AppModel
    let account: AccountConfig

    // 账号信息
    @State private var alias = ""
    @State private var ak = ""
    @State private var sk = ""
    @State private var keysDirty = false
    @State private var credState = TestState.idle

    // 服务
    @State private var enableAgentPlan = false
    @State private var agentTestState = TestState.idle
    @State private var speechApps: [SpeechAppDraft] = []

    @State private var loaded = false
    @State private var savedTick = false   // 保存后短暂显示“已保存”

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    accountInfoSection
                    Divider()
                    servicesSection
                }
                .padding(20)
            }

            Divider()
            HStack {
                if savedTick {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                        .transition(.opacity)
                }
                Spacer()
                Button("保存修改") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty)
            }
            .padding(12)
        }
        .onAppear(perform: load)
    }

    // MARK: 账号信息

    private var accountInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("账号信息", systemImage: "person.text.rectangle")

            LabeledContent("平台") {
                Text(account.platform.displayName).foregroundStyle(.secondary)
            }
            LabeledContent("名称") {
                TextField("显示在面板上", text: $alias)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            if let full = account.accountFullID {
                LabeledContent("账号 ID") {
                    Text(full).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Divider().padding(.vertical, 2)

            LabeledContent("Access Key") {
                RevealableField(title: "Access Key ID", text: $ak)
                    .onChange(of: ak) { keysDirty = true; credState = .idle }
                    .frame(maxWidth: 260)
            }
            LabeledContent("Secret Key") {
                RevealableField(title: "Secret Access Key", text: $sk)
                    .onChange(of: sk) { keysDirty = true; credState = .idle }
                    .frame(maxWidth: 260)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await testCredentials() }
                } label: {
                    if case .testing = credState {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("测试连接")
                    }
                }
                .disabled(ak.isEmpty || sk.isEmpty || credState.isTesting)
                stateLabel(credState)
            }
        }
    }

    // MARK: 服务

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("服务", systemImage: "square.stack.3d.up")

            // Agent Plan（圆角卡片，与语音应用同级）
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "a.circle.fill").foregroundStyle(.secondary)
                    Text("Agent Plan")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: $enableAgentPlan).labelsHidden()
                }
                Text("套餐额度：5 小时 / 每周 / 每月")
                    .font(.caption2).foregroundStyle(.secondary)
                if enableAgentPlan {
                    HStack(spacing: 8) {
                        Button {
                            Task { await testAgentPlan() }
                        } label: {
                            if case .testing = agentTestState {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("测试", systemImage: "bolt.horizontal")
                            }
                        }
                        .controlSize(.small)
                        .disabled(agentTestState.isTesting)
                        stateLabel(agentTestState)
                    }
                }
            }
            .modifier(ServiceCardStyle())

            // 语音应用（每个一张圆角卡片）
            ForEach($speechApps) { $app in
                SpeechAppRow(app: $app, model: model, ak: currentAK, sk: currentSK,
                             onDelete: { speechApps.removeAll { $0.id == app.id } })
            }

            Button {
                if speechApps.count < 10 { speechApps.append(SpeechAppDraft()) }
            } label: {
                Label("添加语音应用", systemImage: "plus")
            }
            .disabled(speechApps.count >= 10)
            if speechApps.count >= 10 {
                Text("最多 10 个语音应用").font(.caption2).foregroundStyle(.tertiary)
            } else if speechApps.isEmpty {
                Text("语音服务（ASR / TTS）：每个应用独立统计额度，可添加多个。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 辅助

    private var currentAK: String { ak }
    private var currentSK: String { sk }

    /// 是否有未保存的修改（与当前 account 配置对比）。
    private var dirty: Bool {
        if keysDirty { return true }
        if alias.trimmingCharacters(in: .whitespacesAndNewlines) != account.alias { return true }
        if enableAgentPlan != account.enableAgentPlan { return true }
        let cur: [SpeechApp] = speechApps.compactMap { d in
            let id = d.appID.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { return nil }
            return SpeechApp(id: d.id, appID: id, label: d.label.trimmingCharacters(in: .whitespaces))
        }
        return cur != account.speechApps
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func stateLabel(_ state: TestState) -> some View {
        switch state {
        case .idle, .testing: EmptyView()
        case .success(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).lineLimit(2)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func testCredentials() async {
        credState = .testing
        let r = await model.testCredentials(ak: ak, sk: sk)
        credState = r.ok ? .success(r.message) : .failure(r.message)
    }

    private func testAgentPlan() async {
        agentTestState = .testing
        let r = await model.testAgentPlan(ak: currentAK, sk: currentSK)
        agentTestState = r.ok ? .success(r.message) : .failure(r.message)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        alias = account.alias
        enableAgentPlan = account.enableAgentPlan
        speechApps = account.speechApps.map { SpeechAppDraft(id: $0.id, appID: $0.appID, label: $0.label) }
        let cred = model.credentials(for: account.id)
        ak = cred.ak; sk = cred.sk
        keysDirty = false
    }

    private func save() {
        let aliasT = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let apps: [SpeechApp] = speechApps.compactMap { d in
            let id = d.appID.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { return nil }
            return SpeechApp(id: d.id, appID: id, label: d.label.trimmingCharacters(in: .whitespaces))
        }
        let newAK: String? = keysDirty ? ak.trimmingCharacters(in: .whitespaces) : nil
        let newSK: String? = keysDirty ? sk.trimmingCharacters(in: .whitespaces) : nil
        model.updateAccount(id: account.id, alias: aliasT, ak: newAK, sk: newSK,
                            accountFullID: account.accountFullID,
                            enableAgentPlan: enableAgentPlan, speechApps: apps)
        keysDirty = false
        withAnimation { savedTick = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { withAnimation { savedTick = false } }
        }
    }
}

struct SpeechAppRow: View {
    @Binding var app: SpeechAppDraft
    let model: AppModel
    let ak: String
    let sk: String
    let onDelete: () -> Void

    @State private var state = TestState.idle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：应用标题（备注或 AppID）+ 删除
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(.secondary)
                Text(headerTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("删除这个语音应用")
            }

            // AppID（带标题）
            VStack(alignment: .leading, spacing: 3) {
                Text("AppID").font(.caption2).foregroundStyle(.secondary)
                TextField("必填，如 3910190874", text: $app.appID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: app.appID) { state = .idle }
            }

            // 备注（带标题）
            VStack(alignment: .leading, spacing: 3) {
                Text("备注（可选）").font(.caption2).foregroundStyle(.secondary)
                TextField("自己起名方便区分，如 “A 应用”", text: $app.label)
                    .textFieldStyle(.roundedBorder)
            }

            // 测试行
            HStack(spacing: 8) {
                Button {
                    Task {
                        state = .testing
                        let r = await model.testSpeechApp(ak: ak, sk: sk, appID: app.appID)
                        state = r.ok ? .success(r.message) : .failure(r.message)
                    }
                } label: {
                    if case .testing = state {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("测试", systemImage: "bolt.horizontal")
                    }
                }
                .controlSize(.small)
                .disabled(app.appID.isEmpty || state.isTesting)
                switch state {
                case .idle, .testing: EmptyView()
                case .success(let m):
                    Label(m, systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green).lineLimit(2)
                case .failure(let m):
                    Label(m, systemImage: "xmark.circle.fill")
                        .font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
        .modifier(ServiceCardStyle())
    }

    private var headerTitle: String {
        let label = app.label.trimmingCharacters(in: .whitespaces)
        if !label.isEmpty { return label }
        let id = app.appID.trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? "新语音应用" : "应用 \(id)"
    }
}

/// 语音应用的编辑草稿（带 UI 状态）。
struct SpeechAppDraft: Identifiable {
    let id: String
    var appID: String
    var label: String
    init(id: String = UUID().uuidString, appID: String = "", label: String = "") {
        self.id = id; self.appID = appID; self.label = label
    }
}

/// 服务卡片统一样式（圆角 + 背景 + 描边），Agent Plan 和语音应用同级。
struct ServiceCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }
}

/// 测试状态。
enum TestState {
    case idle
    case testing
    case success(String)
    case failure(String)

    var isTesting: Bool { if case .testing = self { return true }; return false }
}

// MARK: - 显示 Tab：菜单栏指标 + 刷新间隔

struct DisplayTab: View {
    @Bindable var model: AppModel

    private let intervals: [(String, Int)] = [
        ("1 分钟", 60), ("2 分钟", 120), ("3 分钟", 180), ("5 分钟", 300), ("10 分钟", 600)
    ]

    var body: some View {
        Form {
            Section("菜单栏常驻显示") {
                if model.availableMetrics.isEmpty {
                    Text("暂无可选指标（先在「账号」里添加账号并启用服务）")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("显示指标", selection: Binding(
                        get: { model.selectedMetricID ?? model.availableMetrics.first?.id ?? "" },
                        set: { model.selectedMetricID = $0 }
                    )) {
                        ForEach(model.availableMetrics) { m in
                            Text(m.label).tag(m.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section {
                Picker("Agent Plan", selection: Binding(
                    get: { model.interval(for: .agentPlan) },
                    set: { model.setInterval($0, for: .agentPlan) }
                )) {
                    ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                }
                Picker("语音服务", selection: Binding(
                    get: { model.interval(for: .speech) },
                    set: { model.setInterval($0, for: .speech) }
                )) {
                    ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                }
            } header: {
                Text("刷新间隔（各服务独立）")
            } footer: {
                Text("数据上游有 5–30 分钟延迟，刷新再快数字也不会更早变化。")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 带小眼睛的可显示/隐藏输入框

struct RevealableField: View {
    let title: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))

            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(revealed ? "隐藏" : "显示")
        }
    }
}
