import SwiftUI

/// 一个账号分组：标题 + 该账号下各服务的专属卡片。
struct AccountSectionView: View {
    let account: Account
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(account.accountDisplayName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 16)

            ForEach(account.services) { service in
                ServiceCardView(service: service, account: account, model: model)
                    .padding(.horizontal, 12)
            }
        }
    }
}

/// 服务卡片路由：按 content 形态分发到各服务专属展示视图。
struct ServiceCardView: View {
    let service: Service
    let account: Account
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 服务标题（如「Agent Plan·medium」）
            HStack(spacing: 6) {
                Text(service.title)
                    .font(.system(size: 12, weight: .semibold))
                if case .agentPlan(let plan) = service.content, !plan.tier.isEmpty {
                    badge(plan.tier)
                }
                if case .speech(let pack) = service.content, !pack.type.isEmpty {
                    badge(pack.type)
                }
                Spacer()
                // 语音服务：剩余% 跟服务名同行（与 Agent Plan 窗口行一致，省上下空间）
                if case .speech(let pack) = service.content, !pack.purchased.isEmpty {
                    Text("剩 \(Formatting.percent(pack.remainingPercent))%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(QuotaColor.bar(pack.remainingPercent))
                        .monospacedDigit()
                }
                // 语音服务：整包是单个 metric，标题行尾部提供 "钉到菜单栏" 快捷。
                if case .speech(let pack) = service.content {
                    PinToMenuBarButton(
                        metricID: model.metricID(account: account, service: service, sub: pack.title),
                        currentlyPinned: model.selectedMetricID == model.metricID(account: account, service: service, sub: pack.title)
                    ) {
                        model.selectedMetricID = model.metricID(account: account, service: service, sub: pack.title)
                    }
                }
            }

            switch service.content {
            case .agentPlan(let plan):
                AgentPlanCardView(plan: plan, account: account, service: service, model: model)
            case .speech(let pack):
                SpeechCardView(pack: pack)
            }

            if service.status == .error, let msg = service.errorMessage {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .opacity(service.status == .error ? 0.7 : 1)
    }

    @ViewBuilder
    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
    }
}

/// "钉到菜单栏" 快捷按钮：hover 卡片时显现；当前已是菜单栏指标时高亮。
/// 放面板里就不用再跑去「设置 → 显示」里翻 Picker 选了。
struct PinToMenuBarButton: View {
    let metricID: String
    let currentlyPinned: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: currentlyPinned ? "pin.fill" : "pin")
                .imageScale(.small)
                .foregroundStyle(currentlyPinned ? Color.accentColor : Color.secondary)
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(currentlyPinned ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(currentlyPinned ? "当前菜单栏显示这个指标" : "将这项设为菜单栏显示")
        .opacity(currentlyPinned ? 1 : (hovered ? 1 : 0.35))
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovered)
        .animation(.easeInOut(duration: 0.12), value: currentlyPinned)
    }
}
