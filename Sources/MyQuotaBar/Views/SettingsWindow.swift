import AppKit
import SwiftUI

/// 独立设置窗口：账号管理（增删改）+ 通用设置。
///
/// 交互范式：**改了立即生效**（macOS 系统设置风格）——
/// 改名、拨服务开关、增删语音应用、更换密钥都直接落盘并刷新面板，
/// 没有“保存”按钮、没有草稿、没有未保存拦截。
/// 唯一的例外是“更换密钥”：在弹窗里先测试通过才写入（敏感操作先验证）。
struct SettingsWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            AccountsTab(model: model)
                .tabItem { Label("账号", systemImage: "person.2") }
            GeneralTab(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
        }
        .frame(width: 720, height: 520)
    }
}

// MARK: - 账号 Tab：左边栏账号列表（主）+ 右侧详情（从）—— macOS 经典主从布局

struct AccountsTab: View {
    @Bindable var model: AppModel
    @State private var selectedID: String?
    @State private var addingNew = false
    @State private var deleteTarget: AccountConfig?
    @State private var operationError: String?

    private var selected: AccountConfig? {
        model.accountConfigs.first { $0.id == selectedID }
    }

    private var groupedAccounts: [(platform: Platform, accounts: [AccountConfig])] {
        var platforms: [Platform] = []
        for config in model.accountConfigs where !platforms.contains(config.platform) {
            platforms.append(config.platform)
        }
        return platforms.map { platform in
            (platform, model.accountConfigs.filter { $0.platform == platform })
        }
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
                do {
                    try model.removeAccount(id: target.id)
                    if selectedID == target.id { selectedID = nil }
                } catch {
                    operationError = error.localizedDescription
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { target in
            Text("将从钥匙串删除该账号的密钥，并从面板移除「\(target.alias.isEmpty ? "未命名账号" : target.alias)」的所有服务。此操作不可撤销。")
        }
        .alert("操作失败", isPresented: errorBinding($operationError)) {
            Button("好") { operationError = nil }
        } message: {
            Text(operationError ?? "未知错误")
        }
        .onAppear {
            if selectedID == nil { selectedID = model.accountConfigs.first?.id }
        }
    }

    // 左边栏：账号列表 + 底部 +/− 工具栏
    private var sidebar: some View {
        VStack(spacing: 0) {
            if let warning = model.configurationWarning ?? model.persistenceError {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                Divider()
            }
            List(selection: $selectedID) {
                ForEach(groupedAccounts, id: \.platform) { group in
                    Section(group.platform.displayName) {
                        ForEach(group.accounts) { config in
                            AccountRow(config: config).tag(config.id)
                        }
                        .onMove { model.moveAccounts(in: group.platform, from: $0, to: $1) }
                    }
                }
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
                    Menu {
                        if let selected {
                            let group = model.accountConfigs.filter { $0.platform == selected.platform }
                            let index = group.firstIndex(where: { $0.id == selected.id }) ?? 0
                            Button("上移") { moveSelectedAccount(offset: -1) }
                                .disabled(index == 0)
                            Button("下移") { moveSelectedAccount(offset: 1) }
                                .disabled(index == group.count - 1)
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down").frame(width: 24, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .help("调整账号显示顺序")
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .frame(width: 190)
    }

    private func moveSelectedAccount(offset: Int) {
        guard let selected else { return }
        let group = model.accountConfigs.filter { $0.platform == selected.platform }
        guard let index = group.firstIndex(where: { $0.id == selected.id }) else { return }
        let target = index + offset
        guard group.indices.contains(target) else { return }
        let destination = offset < 0 ? target : target + 1
        model.moveAccounts(in: selected.platform, from: IndexSet(integer: index), to: destination)
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
                    Text("点左下角「+」添加账号：填入 AK/SK 测试连接即可。\n添加后在这里打开 Agent Plan、语音等服务开关，立即生效。\n无需安装任何命令行工具。")
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
        let activeSpeech = config.speechApps.filter { $0.isActive }.count
        if activeSpeech > 0 { parts.append("语音 ×\(activeSpeech)") }
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
    @State private var iamIdentity: String?
    @State private var fetchedName: String?
    @State private var alias = ""
    @State private var saveError: String?

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
                        ForEach(PlatformRegistry.supportedPlatforms, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                } label: {
                    Label("平台", systemImage: "cloud")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledSecretField(label: "Access Key ID（AK）",
                                           placeholder: "Access Key ID", text: $ak)
                            .onChange(of: ak) { resetCred() }
                        LabeledSecretField(label: "Secret Access Key（SK）",
                                           placeholder: "Secret Access Key", text: $sk)
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
        .alert("添加账号失败", isPresented: errorBinding($saveError)) {
            Button("好") { saveError = nil }
        } message: {
            Text(saveError ?? "未知错误")
        }
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
        iamIdentity = nil
        fetchedName = nil
    }

    private func testCredentials() async {
        credState = .testing
        let r = await model.testCredentials(platform: platform, ak: ak, sk: sk)
        if r.ok, let identity = r.identity {
            accountFullID = identity.accountID
            iamIdentity = identity.iamIdentity
            fetchedName = identity.suggestedAccountName
            credState = .success(r.message)
            if alias.trimmingCharacters(in: .whitespaces).isEmpty {
                alias = identity.suggestedAccountName
            }
        } else {
            credState = .failure(r.message)
        }
    }

    private func save() {
        do {
            let newID = try model.addAccount(
                platform: platform,
                alias: alias.trimmingCharacters(in: .whitespacesAndNewlines),
                ak: ak.trimmingCharacters(in: .whitespaces),
                sk: sk.trimmingCharacters(in: .whitespaces),
                accountFullID: accountFullID,
                iamIdentity: iamIdentity,
                enableAgentPlan: false, speechApps: [])
            onAdded(newID)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - 更换密钥弹窗（敏感操作：先测试通过才允许保存）

struct ChangeCredentialsSheet: View {
    @Bindable var model: AppModel
    let accountID: String
    let platform: Platform
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var ak = ""
    @State private var sk = ""
    @State private var state = TestState.idle
    @State private var verified = false
    @State private var verifiedAccountID = ""
    @State private var verifiedIdentity: String?
    @State private var error: String?

    private var canTest: Bool {
        !ak.trimmingCharacters(in: .whitespaces).isEmpty
            && !sk.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("更换密钥").font(.headline).padding(.top, 16)

            VStack(alignment: .leading, spacing: 14) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledSecretField(label: "Access Key ID（AK）",
                                           placeholder: "Access Key ID", text: $ak)
                            .onChange(of: ak) { invalidate() }
                        LabeledSecretField(label: "Secret Access Key（SK）",
                                           placeholder: "Secret Access Key", text: $sk)
                            .onChange(of: sk) { invalidate() }
                        HStack(spacing: 8) {
                            Button {
                                Task { await testCredentials() }
                            } label: {
                                if case .testing = state {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("测试连接")
                                }
                            }
                            .disabled(!canTest || state.isTesting)
                            stateLabel(state)
                        }
                        Text("填入新的 AK/SK，先点「测试连接」，通过后才能保存。加密存入 macOS 钥匙串。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } label: {
                    Label("新的火山引擎密钥（AK / SK）", systemImage: "key")
                }
            }
            .padding(16)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存密钥") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!verified)
            }
            .padding(12)
        }
        .frame(width: 460, height: 340)
        .onAppear {
            let cred = model.credentials(for: accountID)
            ak = cred.ak
            sk = cred.sk
        }
        .alert("保存密钥失败", isPresented: errorBinding($error)) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "未知错误")
        }
    }

    @ViewBuilder
    private func stateLabel(_ s: TestState) -> some View {
        switch s {
        case .idle, .testing: EmptyView()
        case .success(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).lineLimit(2)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func invalidate() {
        state = .idle
        verified = false
        verifiedAccountID = ""
        verifiedIdentity = nil
    }

    private func testCredentials() async {
        state = .testing
        let r = await model.testCredentials(platform: platform, ak: ak, sk: sk)
        if r.ok, let identity = r.identity {
            state = .success(r.message)
            verified = true
            verifiedAccountID = identity.accountID
            verifiedIdentity = identity.iamIdentity
        } else {
            state = .failure(r.message)
            verified = false
        }
    }

    private func save() {
        do {
            try model.changeCredentials(
                id: accountID,
                ak: ak.trimmingCharacters(in: .whitespaces),
                sk: sk.trimmingCharacters(in: .whitespaces),
                accountFullID: verifiedAccountID,
                iamIdentity: verifiedIdentity
            )
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 账号详情（右侧）：「账号 / 套餐 / 语音」三个平级分组，改了立即生效

struct AccountDetailView: View {
    @Bindable var model: AppModel
    let account: AccountConfig

    @State private var speechApps: [SpeechAppDraft] = []
    @State private var agentTestState = TestState.idle
    @State private var showCredSheet = false
    // 更换密钥成功后 +1，用于强制重建服务行、清掉旧的测试结果。
    @State private var serviceEpoch = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                accountGroup
                if account.platform.isSupported {
                    planGroup
                    speechGroup.id(serviceEpoch)
                } else {
                    unsupportedPlatformView
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showCredSheet) {
            ChangeCredentialsSheet(model: model, accountID: account.id, platform: account.platform) {
                agentTestState = .idle
                serviceEpoch += 1
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: syncSpeechApps)
    }

    private var unsupportedPlatformView: some View {
        ContentUnavailableView(
            "当前版本暂不支持此平台",
            systemImage: "questionmark.app.dashed",
            description: Text("平台标识 \(account.platform.rawValue) 已原样保留，不会按火山引擎请求或改写。")
        )
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: 账号分组

    private var accountGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("账号", systemImage: "person.text.rectangle")

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    // 行 1：名称（可改） + 更换密钥
                    HStack(spacing: 10) {
                        Text("名称").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                        TextField("显示在面板上，可改成好认的名字", text: aliasBinding)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            showCredSheet = true
                        } label: {
                            Label("更换密钥…", systemImage: "key")
                        }
                        .controlSize(.small)
                    }
                    // 行 2：平台 · 身份 · 账号 ID（紧凑一行，可复制）
                    HStack(spacing: 8) {
                        Text("账号").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                        Text(identityLine)
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if account.accountFullID != nil {
                            Button {
                                copyAccountID()
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless).controlSize(.small)
                            .foregroundStyle(.secondary)
                            .help("复制账号 ID")
                        }
                        Spacer()
                    }
                }
                .padding(6)
            }
        }
    }

    /// 紧凑身份行：平台 · 主账号/子用户 · 账号 ID。
    private var identityLine: String {
        var parts: [String] = [account.platform.displayName]
        if let badge = account.identityBadge { parts.append(badge) }
        if let full = account.accountFullID { parts.append("ID \(full)") }
        return parts.joined(separator: " · ")
    }

    private func copyAccountID() {
        guard let id = account.accountFullID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

    private var aliasBinding: Binding<String> {
        Binding(
            get: { account.alias },
            set: { model.setAlias(id: account.id, alias: $0) }
        )
    }

    // MARK: 套餐分组（订阅套餐类服务；现在是 Agent Plan，以后有别的套餐加这里）

    private var planGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("套餐", systemImage: "creditcard")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "a.circle.fill").foregroundStyle(.secondary)
                    Text("Agent Plan").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    // 测试按钮常显（开关未开也能先验证），与语音应用卡的测试按钮同在右侧。
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
                    Toggle("", isOn: agentPlanBinding).labelsHidden()
                }
                HStack(spacing: 8) {
                    Text("套餐额度：5 小时 / 每周 / 每月")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    CompactTestStateLabel(state: agentTestState)
                }
            }
            .modifier(ServiceCardStyle())
        }
    }

    // MARK: 语音分组（语音应用与 Agent Plan 同级；每个应用内 ASR / TTS 独立开关）

    private var speechGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("语音", systemImage: "waveform")
                Spacer()
                Button {
                    if speechApps.count < 10 { speechApps.append(SpeechAppDraft()) }
                } label: {
                    Label("添加应用", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(speechApps.count >= 10)
                .help(speechApps.count >= 10 ? "最多 10 个语音应用" : "添加一个语音应用（AppID）")
            }

            if speechApps.isEmpty {
                Text("还没有语音应用。点右上角「添加应用」填入 AppID；ASR / TTS 可分别开关。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.25),
                                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
            } else {
                VStack(spacing: 8) {
                    ForEach($speechApps) { $app in
                        SpeechAppRow(
                            app: $app,
                            model: model,
                            ak: currentCreds.ak,
                            sk: currentCreds.sk,
                            onCommit: syncSpeechApps,
                            onDelete: {
                                speechApps.removeAll { $0.id == app.id }
                                syncSpeechApps()
                            }
                        )
                    }
                }
            }
        }
    }

    private var agentPlanBinding: Binding<Bool> {
        Binding(get: { account.enableAgentPlan },
                set: { model.setAgentPlanEnabled(id: account.id, enabled: $0) })
    }

    private var currentCreds: (ak: String, sk: String) {
        model.credentials(for: account.id)
    }

    // MARK: 辅助

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.primary)
    }

    private func testAgentPlan() async {
        agentTestState = .testing
        let cred = model.credentials(for: account.id)
        let r = await model.testAgentPlan(ak: cred.ak, sk: cred.sk)
        agentTestState = r.ok ? .success(r.message) : .failure(r.message)
    }

    private func load() {
        speechApps = account.speechApps.map {
            SpeechAppDraft(id: $0.id, appID: $0.appID, label: $0.label,
                           enableASR: $0.enableASR, enableTTS: $0.enableTTS)
        }
    }

    /// 把本地草稿里“AppID 有效”的应用同步到 model（立即落盘 + 刷新）。
    /// AppID 为空/非法的草稿只留在界面上，不入库、不拉数。
    private func syncSpeechApps() {
        let valid = speechApps.compactMap { draft -> SpeechApp? in
            let appID = draft.appID.trimmingCharacters(in: .whitespaces)
            guard let id = Int(appID), id > 0 else { return nil }
            return SpeechApp(
                id: draft.id, appID: appID,
                label: draft.label.trimmingCharacters(in: .whitespaces),
                enableASR: draft.enableASR, enableTTS: draft.enableTTS
            )
        }
        model.setSpeechApps(id: account.id, apps: valid)
    }
}

struct SpeechAppRow: View {
    @Binding var app: SpeechAppDraft
    let model: AppModel
    let ak: String
    let sk: String
    let onCommit: () -> Void
    let onDelete: () -> Void

    @State private var state = TestState.idle

    private var appIDValid: Bool {
        Int(app.appID.trimmingCharacters(in: .whitespaces)).map { $0 > 0 } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 行 1：标题 + 测试 + 删除
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(headerTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    onCommit()
                    Task {
                        state = .testing
                        let r = await model.testSpeechApp(
                            ak: ak, sk: sk, appID: app.appID,
                            includeASR: app.enableASR, includeTTS: app.enableTTS)
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
                .disabled(!appIDValid || (!app.enableASR && !app.enableTTS) || state.isTesting)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .help("删除这个语音应用")
            }

            // 行 2：AppID（窄框）+ 备注（弹性）并排
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 5) {
                    Text("AppID").font(.caption2).foregroundStyle(.secondary)
                    TextField("填入语音 AppID", text: $app.appID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 116)
                        .onSubmit(onCommit)
                        .onChange(of: app.appID) { state = .idle }
                }
                HStack(spacing: 5) {
                    Text("备注").font(.caption2).foregroundStyle(.secondary)
                    TextField("可选，便于区分", text: $app.label)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit(onCommit)
                }
            }

            // 行 3：ASR / TTS 复选框 + 测试状态
            HStack(spacing: 16) {
                Toggle("语音识别 ASR", isOn: $app.enableASR)
                    .toggleStyle(.checkbox)
                    .onChange(of: app.enableASR) { onCommit() }
                Toggle("语音合成 TTS", isOn: $app.enableTTS)
                    .toggleStyle(.checkbox)
                    .onChange(of: app.enableTTS) { onCommit() }
                Spacer()
                if !app.enableASR && !app.enableTTS {
                    Text("未启用（面板不显示）")
                        .font(.caption2).foregroundStyle(.orange)
                } else {
                    CompactTestStateLabel(state: state)
                }
            }
            .font(.system(size: 12))
        }
        .modifier(ServiceCardStyle())
    }

    private var headerTitle: String {
        let label = app.label.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? "语音应用" : label
    }
}

/// 语音应用的编辑草稿（带 UI 状态）。
struct SpeechAppDraft: Identifiable {
    let id: String
    var appID: String
    var label: String
    var enableASR: Bool
    var enableTTS: Bool
    init(id: String = UUID().uuidString, appID: String = "", label: String = "",
         enableASR: Bool = true, enableTTS: Bool = true) {
        self.id = id
        self.appID = appID
        self.label = label
        self.enableASR = enableASR
        self.enableTTS = enableTTS
    }
}

/// 服务卡片统一样式（圆角 + 背景 + 描边），Agent Plan 和语音应用同级。
struct ServiceCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(8)
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

/// 紧凑测试状态：只显示「正常 / 失败」，完整消息悬停可见（失败详情在面板卡片上也会显示）。
struct CompactTestStateLabel: View {
    let state: TestState

    var body: some View {
        switch state {
        case .idle, .testing:
            EmptyView()
        case .success(let msg):
            Label("正常", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green).help(msg)
        case .failure(let msg):
            Label("失败", systemImage: "xmark.circle.fill")
                .font(.caption2).foregroundStyle(.red).help(msg)
        }
    }
}

/// 把可选错误文案桥接成 Alert 所需的布尔 Binding。
private func errorBinding(_ message: Binding<String?>) -> Binding<Bool> {
    Binding(
        get: { message.wrappedValue != nil },
        set: { if !$0 { message.wrappedValue = nil } }
    )
}

// MARK: - 通用 Tab：菜单栏指标 + 刷新间隔 + 开机启动 + 版本

struct GeneralTab: View {
    @Bindable var model: AppModel

    private let intervals: [(String, Int)] = [
        ("1 分钟", 60), ("2 分钟", 120), ("3 分钟", 180), ("5 分钟", 300), ("10 分钟", 600)
    ]

    @State private var launchOn = LoginItem.isEnabled
    @State private var launchError: String?

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
                Picker("刷新间隔", selection: Binding(
                    get: { model.globalRefreshInterval },
                    set: { model.setGlobalRefreshInterval($0) }
                )) {
                    ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                }
            } header: {
                Text("刷新")
            } footer: {
                Text("数据上游有 5–30 分钟延迟，刷新再快数字也不会更早变化。")
                    .font(.caption)
            }

            Section("启动") {
                Toggle("开机自动启动 My Quota Bar", isOn: launchBinding)
            }

            Section {
                LabeledContent("版本") {
                    Text(Self.appVersion).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .alert("开机启动设置失败", isPresented: errorBinding($launchError)) {
            Button("好") { launchError = nil }
        } message: {
            Text(launchError ?? "未知错误")
        }
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchOn },
            set: { newValue in
                launchOn = newValue
                do {
                    try LoginItem.setEnabled(newValue)
                } catch {
                    launchError = error.localizedDescription
                    launchOn = LoginItem.isEnabled
                }
            }
        )
    }

    private static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short ?? "—"
    }
}

// MARK: - 带明确标签和小眼睛的密钥输入框

struct LabeledSecretField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Group {
                    if revealed {
                        TextField(placeholder, text: $text)
                    } else {
                        SecureField(placeholder, text: $text)
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
}
