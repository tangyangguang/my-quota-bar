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
/// 布局约定：所有「可作为菜单栏指标」的内容单元，都用 `.metricRow(...)` 包裹，
/// 由 modifier 在右上角统一插上同一个 PinBadge。这样 pin 图标的位置永远一致，
/// 眼睛不需要在不同服务里重新适应锚点。
struct ServiceCardView: View {
    let service: Service
    let account: Account
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 服务标题（如「Agent Plan·medium」或「应用 1234 · 语音识别 ASR」）
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
            }

            switch service.content {
            case .agentPlan(let plan):
                AgentPlanCardView(plan: plan, account: account, service: service, model: model)
            case .speech(let pack):
                SpeechCardView(pack: pack, account: account, service: service, model: model)
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

/// 一行可作为菜单栏指标的视图的修饰：
/// - 在该行右上角固定插一个可点击的 PinBadge
/// - 鼠标悬停该行任意位置时浮现（未钉状态）
/// - 已钉时常显，主题色 + 弹性动画
///
/// 关键是位置：所有 metric 行都遵偈同一个右上方锚点，不随内容不同而跳动。
struct MetricRowModifier: ViewModifier {
    let isPinned: Bool
    let action: () -> Void

    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                Button(action: action) {
                    PinBadge(isPinned: isPinned, hovered: hovered)
                }
                .buttonStyle(.plain)
                .padding(.top, -2)     // 贴近上边，避开 “剩 X%” 中部
                .padding(.trailing, -2) // 略微超出右边，看起来是 “钉上去”
                .opacity(isPinned ? 1 : (hovered ? 1 : 0))
                .animation(.easeOut(duration: 0.12), value: hovered)
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isPinned)
                .help(isPinned ? "当前菜单栏显示这个指标" : "点击钉为菜单栏常驻显示")
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

extension View {
    /// 标记该 View 为一个「可钉为菜单栏」的指标行。
    /// - Parameters:
    ///   - isPinned: 是否当前是菜单栏显示的指标
    ///   - action: 点击 PinBadge 时的动作
    func metricRow(isPinned: Bool, action: @escaping () -> Void) -> some View {
        modifier(MetricRowModifier(isPinned: isPinned, action: action))
    }
}

/// 右上角的小徽章：empty pin → hover浮现；pinned → 常显 + 主题色。
/// 保持紧凑：只一个 pin 图标 + 软背景，从远处也能一眼看出「这个是菜单栏指标」。
struct PinBadge: View {
    let isPinned: Bool
    let hovered: Bool

    var body: some View {
        Image(systemName: isPinned ? "pin.fill" : "pin")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(isPinned ? Color.white : Color.accentColor)
            .frame(width: 18, height: 18)
            .background(
                Circle().fill(
                    isPinned
                    ? Color.accentColor
                    : Color(nsColor: .windowBackgroundColor).opacity(0.96)
                )
            )
            .overlay(
                Circle().stroke(
                    isPinned ? Color.clear : Color.accentColor.opacity(0.4),
                    lineWidth: 0.5
                )
            )
            .shadow(
                color: .black.opacity(isPinned ? 0.22 : 0.10),
                radius: isPinned ? 2 : 1.2, y: 1
            )
            .scaleEffect(isPinned ? 1.0 : (hovered ? 1.0 : 0.88))
    }
}
