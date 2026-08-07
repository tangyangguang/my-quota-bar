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
/// 「钉为菜单栏」实现遵循 macOS 原生范式：整行可点击 = 切换；
/// 当前选中项靠「背景色微变 + 左侧淑出光带」表达——轻量暗示。
/// **不靠加色条/加粗/换色，靠柔的背景与淑出光晕**。原 UI 100% 保留，位置不动。
struct ServiceCardView: View {
    let service: Service
    let account: Account
    @Bindable var model: AppModel

    var body: some View {
        // 卡片内容（标题行 + 服务详情 + 错误信息）。原 UI 一字不动。
        let content = VStack(alignment: .leading, spacing: 8) {
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

        // 语音服务：整张 service 卡片是 1 个指标 → 整张可点击。
        // Agent Plan：每个 period 各自是 1 个指标 → 在 AgentPlanCardView 里逐行套 menuBarPinRow。
        if case .speech(let pack) = service.content, !pack.purchased.isEmpty {
            let mid = model.metricID(account: account, service: service, sub: pack.title)
            content
                .menuBarPinRow(
                    isPinned: model.selectedMetricID == mid,
                    action: { model.selectedMetricID = mid }
                )
        } else {
            content
        }
    }

    /// 服务标题行：语音服务会在右端显示「剩 X%」（保持原样）。
    @ViewBuilder
    private var titleRow: some View {
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
            if case .speech(let pack) = service.content, !pack.purchased.isEmpty {
                Text("剩 \(Formatting.percent(pack.remainingPercent))%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuotaColor.bar(pack.remainingPercent))
                    .monospacedDigit()
            }
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

/// 「钉为菜单栏」View Modifier：把一个可作为菜单栏指标的整行变成可点击项。
///
/// 设计原则（macOS 原生范式）：
/// 1. **整行可点击** = 钉为菜单栏（cursor: pointer / hover 高亮 / tooltip 提示）
/// 2. **当前菜单栏在显示的那一项**靠「背景色微变 + 左侧极淡渐变光带」表达，克制轻量——
///    色条原本是「色色声明」，换成从左向右淑出的渐变光晕，变成「光的暗示」。
/// 3. 原 UI 100% 保留：标签、剩 X%、进度条、tier badge 位置、颜色一概不动。
///
/// 【叠加】用 .overlay（不是 .background）作背景叠层，以避免被原视图的 controlBackground
/// 背景遮住。仅在 pinned / hover 时添加色块，不影响任何原背景。
struct MenuBarPinRowModifier: ViewModifier {
    let isPinned: Bool
    let action: () -> Void

    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .overlay {
                // 背景叠层：已钉=柔的主题色;hover=更谈的 accent;
                // 使用 RoundedRectangle 贴合原视图的圆角。
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isPinned
                        ? Color.accentColor.opacity(hovered ? 0.10 : 0.07)
                        : (hovered ? Color.accentColor.opacity(0.04) : Color.clear)
                    )
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.15), value: isPinned)
                    .animation(.easeOut(duration: 0.12), value: hovered)
            }
            .overlay(alignment: .leading) {
                // 已钉时从左向右淑出的极淡渐变光带（不是色条）——
                // 6% 主题色、宽 16pt、向右淑出至 0。
                // 只有已钉时才出现；hover 时不出现，状态区分明确。
                if isPinned {
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.06),
                            Color.accentColor.opacity(0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 16)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { action() }
            .onHover { hovered = $0 }
            .help(isPinned
                  ? "当前菜单栏显示这个指标。点击切换到其他项"
                  : "点击钉为菜单栏常驻显示")
            .animation(.easeOut(duration: 0.18), value: isPinned)
    }
}

extension View {
    /// 把一行标记为「可钉为菜单栏」的指标行：整行可点击，当前项靠背景微变 + 左侧淑出光带表达。
    /// - Parameters:
    ///   - isPinned: 是否当前是菜单栏显示的指标
    ///   - action: 点击该行时调用的切换动作
    func menuBarPinRow(isPinned: Bool, action: @escaping () -> Void) -> some View {
        modifier(MenuBarPinRowModifier(isPinned: isPinned, action: action))
    }
}
