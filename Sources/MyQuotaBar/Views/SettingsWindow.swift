import SwiftUI

// MARK: - 设置草稿：所有编辑先暂存，点“保存并应用”才生效，“取消”丢弃。

@MainActor
@Observable
final class SettingsDraft {
    var selectedMetricID = ""
    var intervalAgent = 180
    var intervalSpeech = 180
    var agentPlanProfile = ""
    var ak = ""
    var sk = ""
    var appID = ""
    var aliases: [String: String] = [:]   // accountID -> 别名输入框内容
    var hidden: Set<String> = []          // 被隐藏的服务 ID

    /// 从当前生效状态载入（每次打开设置窗口时调用）。
    func load(from model: AppModel) {
        selectedMetricID = model.currentMetric?.id ?? ""
        intervalAgent = model.interval(for: .agentPlan)
        intervalSpeech = model.interval(for: .speech)
        agentPlanProfile = model.arkPlanProfile
        ak = SpeechCredentials.accessKeyID
        sk = SpeechCredentials.secretAccessKey
        appID = SpeechCredentials.appID
        hidden = model.hiddenServiceIDs
        aliases = [:]
        for a in model.accounts { aliases[a.id] = a.effectiveName }
    }

    /// 一次性把全部草稿应用到模型 + 持久化，并触发刷新。
    func apply(to model: AppModel) {
        if !selectedMetricID.isEmpty { model.selectedMetricID = selectedMetricID }
        model.setInterval(intervalAgent, for: .agentPlan)
        model.setInterval(intervalSpeech, for: .speech)
        if agentPlanProfile != model.arkPlanProfile, !agentPlanProfile.isEmpty {
            model.selectAgentPlanProfile(agentPlanProfile)
        }
        model.hiddenServiceIDs = hidden

        for a in model.accounts {
            let trimmed = (aliases[a.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            model.setAlias((trimmed.isEmpty || trimmed == a.defaultName) ? nil : trimmed, for: a.id)
        }

        let akT = ak.trimmingCharacters(in: .whitespacesAndNewlines)
        let skT = sk.trimmingCharacters(in: .whitespacesAndNewlines)
        let idT = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        if akT.isEmpty && skT.isEmpty && idT.isEmpty {
            SpeechCredentials.accessKeyID = ""
            SpeechCredentials.secretAccessKey = ""
            SpeechCredentials.appID = ""
            model.clearSpeechAccount()
        } else {
            SpeechCredentials.accessKeyID = akT
            SpeechCredentials.secretAccessKey = skT
            SpeechCredentials.appID = idT
        }
        model.refresh()
    }
}

/// 独立设置窗口：暂存式编辑 + 底部统一「保存并应用 / 取消」。
struct SettingsWindow: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SettingsDraft()

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                DisplaySettingsTab(model: model, draft: draft)
                    .tabItem { Label("显示", systemImage: "menubar.rectangle") }
                AccountsServicesTab(model: model, draft: draft)
                    .tabItem { Label("账号与服务", systemImage: "checklist") }
                CredentialsTab(model: model, draft: draft)
                    .tabItem { Label("密钥", systemImage: "key") }
            }

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存并应用") {
                    draft.apply(to: model)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 500, height: 480)
        .onAppear { draft.load(from: model) }
    }
}

// MARK: - Tab 1：菜单栏显示 + 各源刷新间隔

struct DisplaySettingsTab: View {
    let model: AppModel
    @Bindable var draft: SettingsDraft

    private let intervals: [(String, Int)] = [
        ("1 分钟", 60), ("2 分钟", 120), ("3 分钟", 180), ("5 分钟", 300), ("10 分钟", 600)
    ]

    var body: some View {
        Form {
            Section("菜单栏常驻显示") {
                if model.availableMetrics.isEmpty {
                    Text("暂无可选指标").foregroundStyle(.secondary)
                } else {
                    Picker("显示指标", selection: $draft.selectedMetricID) {
                        ForEach(model.availableMetrics) { m in
                            Text(m.label).tag(m.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section {
                Picker("火山引擎 · Agent Plan", selection: $draft.intervalAgent) {
                    ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                }
                Picker("火山引擎 · 语音服务", selection: $draft.intervalSpeech) {
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

// MARK: - Tab 2：账号别名 + 服务显示/隐藏（两级）

struct AccountsServicesTab: View {
    let model: AppModel
    @Bindable var draft: SettingsDraft

    var body: some View {
        Form {
            if model.accounts.isEmpty {
                Section { Text("暂无账号").foregroundStyle(.secondary) }
            }
            ForEach(model.accounts) { account in
                Section {
                    // 别名编辑（暂存，保存后生效）
                    HStack(spacing: 6) {
                        TextField("账号别名", text: Binding(
                            get: { draft.aliases[account.id] ?? account.effectiveName },
                            set: { draft.aliases[account.id] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("重置") { draft.aliases[account.id] = account.defaultName }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("把输入框恢复为默认名（自动获取的用户名）")
                    }
                    Text("默认名：\(account.defaultName.isEmpty ? "（未获取到）" : account.defaultName)　账号 ID：\(account.fullID ?? "未知")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    // 该账号下的服务开关
                    ForEach(account.services) { service in
                        Toggle(service.title, isOn: Binding(
                            get: { !draft.hidden.contains("\(account.id)/\(service.id)") },
                            set: { on in
                                let key = "\(account.id)/\(service.id)"
                                if on { draft.hidden.remove(key) } else { draft.hidden.insert(key) }
                            }
                        ))
                    }
                } header: {
                    Text(account.platform)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tab 3：Agent Plan profile + 语音密钥

struct CredentialsTab: View {
    let model: AppModel
    @Bindable var draft: SettingsDraft
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                if model.arkProfiles.isEmpty {
                    Text("未检测到 arkcli profile。请先安装 arkcli 并登录。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Agent Plan 账号", selection: $draft.agentPlanProfile) {
                        ForEach(model.arkProfiles) { p in
                            Text("\(p.displayName)（\(p.name)）").tag(p.name)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("火山引擎 · Agent Plan")
            } footer: {
                Text("选择你自己的 arkcli profile（类型为 agent-plan 的那个）。凭证走本机 arkcli 登录态，无需在此填写。")
                    .font(.caption)
            }

            Section {
                RevealableField(title: "Access Key ID", text: $draft.ak)
                RevealableField(title: "Secret Access Key", text: $draft.sk)
                TextField("应用 AppID", text: $draft.appID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            } header: {
                Text("火山引擎 · 语音服务（ASR / TTS）密钥")
            } footer: {
                Text("Access Key / Secret Key 加密存入 macOS 钥匙串，纯本地。三项填全才会显示语音额度。")
                    .font(.caption)
            }

            // 危险操作单独一区，远离保存
            Section {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("清空密钥", systemImage: "trash")
                }
                .disabled(draft.ak.isEmpty && draft.sk.isEmpty && draft.appID.isEmpty)
                .confirmationDialog(
                    "确定清空语音密钥？",
                    isPresented: $confirmClear,
                    titleVisibility: .visible
                ) {
                    Button("清空", role: .destructive) {
                        draft.ak = ""; draft.sk = ""; draft.appID = ""
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("清空后点“保存并应用”才生效，届时会从面板移除语音服务。此刻取消或关闭窗口不会改动已保存的密钥。")
                }
            } footer: {
                Text("清空只清输入框；保存后才真正从钥匙串删除。")
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
