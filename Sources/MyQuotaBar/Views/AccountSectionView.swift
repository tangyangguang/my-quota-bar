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
///
/// 「钉为菜单栏」快捷方式作为 .menuBarPin(...) 修饰插上——
/// 原 UI 一动不动，徽章用 overlay 浮在右上角、不参与布局。
struct ServiceCardView: View {
    let service: Service
    let account: Account
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 服务标题行（如「Agent Plan·medium」或「应用 1234 · 语音识别 ASR」）。
            // 「剩 X%」仍在该行右端，原布局不动。
            // 语音服务作为单个指标行，右上角浮 pin 圆；Agent Plan 每个 period 各自右上有 pin。
            titleRow

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

    /// 服务标题行：语音服务会同时被赋予「钉为菜单栏」的右上角 pin 圆。
    @ViewBuilder
    private var titleRow: some View {
        let row = HStack(spacing: 6) {
            Text(service.title)
                .font(.system(size: 12, weight: .semibold))
            if case .agentPlan(let plan) = service.content, !plan.tier.isEmpty {
                badge(plan.tier)
            }
            if case .speech(let pack) = service.content, !pack.type.isEmpty {
                badge(pack.type)
            }
            Spacer()
            if case .speech(let pack) = service.content, !pack.purchased.isEmpty {
                Text("剩 \(Formatting.percent(pack.remainingPercent))%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuotaColor.bar(pack.remainingPercent))
                    .monospacedDigit()
            }
        }
        if case .speech(let pack) = service.content, !pack.purchased.isEmpty {
            let mid = model.metricID(account: account, service: service, sub: pack.title)
            row.menuBarPin(
                isPinned: model.selectedMetricID == mid,
                action: { model.selectedMetricID = mid }
            )
        } else {
            row
        }
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

/// 「钉为菜单栏」View Modifier：
/// - 在 row 右上角浮一个微小的 pin 圆点（原布局完全不动）
/// - 未钉 + 未 hover：不渲染任何东西（零视觉噪音）
/// - 未钉 + hover：出现软背景下的小 pin 圆
/// - 已钉：常显主题色实心 pin 圆
/// - 点击圆点：切换菜单栏指标
///
/// 【位置】徽章不参与布局，用 .overlay(alignment: .topTrailing) 盖在 row 的角上，
/// 偏上 -2pt、偏右 -2pt，让小圆真正贴近右上角，不挤占「剩 X%」的布局位置。
struct MenuBarPinModifier: ViewModifier {
    let isPinned: Bool
    let action: () -> Void

    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if isPinned || hovered {
                    Button(action: action) {
                        PinDot(isPinned: isPinned)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, -2)
                    .padding(.trailing, -2)
                    .transition(.scale.combined(with: .opacity))
                    .help(isPinned ? "当前菜单栏显示这个指标" : "点击钉为菜单栏常驻显示")
                }
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isPinned)
    }
}

extension View {
    /// 在原视图右上角浮一个「钉为菜单栏」的快捷圆点。不影响原布局。
    /// - Parameters:
    ///   - isPinned: 是否当前是菜单栏显示的指标
    ///   - action: 点击时调用的切换动作
    func menuBarPin(isPinned: Bool, action: @escaping () -> Void) -> some View {
        modifier(MenuBarPinModifier(isPinned: isPinned, action: action))
    }
}

/// 徽章本身：只一个 14pt 圆 + pin 图标。极小，不抢戏。
struct PinDot: View {
    let isPinned: Bool

    var body: some View {
        Image(systemName: isPinned ? "pin.fill" : "pin")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(isPinned ? Color.white : Color.accentColor)
            .frame(width: 14, height: 14)
            .background(
                Circle().fill(
                    isPinned
                    ? Color.accentColor
                    : Color(nsColor: .windowBackgroundColor).opacity(0.96)
                )
            )
            .overlay(
                Circle().stroke(
                    isPinned ? Color.clear : Color.accentColor.opacity(0.45),
                    lineWidth: 0.5
                )
            )
            .shadow(
                color: .black.opacity(isPinned ? 0.22 : 0.12),
                radius: isPinned ? 1.6 : 1.0, y: 0.6
            )
    }
}
