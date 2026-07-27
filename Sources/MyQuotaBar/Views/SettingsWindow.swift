import SwiftUI

/// 独立设置窗口（方案 C）：分区组织，空间充足，永不超出菜单栏面板。
struct SettingsWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            DisplaySettingsTab(model: model)
                .tabItem { Label("显示", systemImage: "menubar.rectangle") }

            ServicesSettingsTab(model: model)
                .tabItem { Label("服务", systemImage: "checklist") }

            AccountsSettingsTab(model: model)
                .tabItem { Label("密钥", systemImage: "key") }
        }
        .frame(width: 480, height: 440)
    }
}

// MARK: - Tab 1：菜单栏显示 + 各源刷新间隔

struct DisplaySettingsTab: View {
    @Bindable var model: AppModel

    private let intervals: [(String, Int)] = [
        ("1 分钟", 60), ("2 分钟", 120), ("3 分钟", 180), ("5 分钟", 300), ("10 分钟", 600)
    ]

    var body: some View {
        Form {
            Section("菜单栏常驻显示") {
                if model.availableMetrics.isEmpty {
                    Text("暂无可选指标").foregroundStyle(.secondary)
                } else {
                    Picker("显示指标", selection: Binding(
                        get: { model.currentMetric?.id ?? "" },
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
                ForEach(AppModel.RefreshSource.allCases, id: \.self) { source in
                    Picker(source.displayName, selection: Binding(
                        get: { model.interval(for: source) },
                        set: { model.setInterval($0, for: source) }
                    )) {
                        ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    .pickerStyle(.menu)
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

// MARK: - Tab 2：服务显示/隐藏

struct ServicesSettingsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.accounts.isEmpty {
                    Text("暂无服务").foregroundStyle(.secondary)
                }
                ForEach(model.accounts) { account in
                    ForEach(account.services) { service in
                        Toggle(isOn: Binding(
                            get: { model.isServiceVisible(accountID: account.id, serviceID: service.id) },
                            set: { model.setService(accountID: account.id, serviceID: service.id, visible: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(service.title).font(.system(size: 13))
                                Text(account.name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("选择在面板显示哪些服务")
            } footer: {
                Text("关闭后该服务不在面板显示、也不出现在菜单栏可选项里（比如额度用完不想看）。")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tab 3：语音服务密钥（AK/SK）

struct AccountsSettingsTab: View {
    @Bindable var model: AppModel
    @State private var ak = ""
    @State private var sk = ""
    @State private var appID = ""
    @State private var savedTip = false

    var body: some View {
        Form {
            Section {
                if model.arkProfiles.isEmpty {
                    Text("未检测到 arkcli profile。请先安装 arkcli 并登录。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Agent Plan 账号", selection: Binding(
                        get: { model.arkPlanProfile },
                        set: { model.selectAgentPlanProfile($0) }
                    )) {
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
                RevealableField(title: "Access Key ID", text: $ak)
                RevealableField(title: "Secret Access Key", text: $sk)
                TextField("应用 AppID", text: $appID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                HStack {
                    Button("保存并刷新") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(ak.isEmpty || sk.isEmpty || appID.isEmpty)
                    if SpeechCredentials.isConfigured {
                        Button("清除") { clear() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    if savedTip {
                        Label("已保存到钥匙串", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else if SpeechCredentials.isConfigured {
                        Label("已配置", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            } header: {
                Text("火山引擎 · 语音服务（ASR / TTS）密钥")
            } footer: {
                Text("Access Key / Secret Key 加密存入 macOS 钥匙串，纯本地。配置后才会显示语音额度；清除后自动隐藏。")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ak = SpeechCredentials.accessKeyID
            sk = SpeechCredentials.secretAccessKey
            appID = SpeechCredentials.appID
        }
    }

    private func save() {
        SpeechCredentials.accessKeyID = ak.trimmingCharacters(in: .whitespacesAndNewlines)
        SpeechCredentials.secretAccessKey = sk.trimmingCharacters(in: .whitespacesAndNewlines)
        SpeechCredentials.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        savedTip = true
        model.refresh()
    }

    private func clear() {
        SpeechCredentials.accessKeyID = ""
        SpeechCredentials.secretAccessKey = ""
        ak = ""; sk = ""
        savedTip = false
        model.clearSpeechAccount()
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
