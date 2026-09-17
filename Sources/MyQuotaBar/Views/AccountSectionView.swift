import SwiftUI

/// 一个账号分组：标题（可点折叠）+ 该账号下各服务的专属卡片；
/// 折叠后收成一张摘要小卡（各指标短标签 + 带色剩余百分比）。
struct AccountSectionView: View {
    let account: Account
    @Bindable var model: AppModel
    @State private var hovered = false
    @State private var showReauth = false

    private var isCollapsed: Bool { model.collapsedAccounts.contains(account.id) }
    /// chevron：折叠时常显（保证能发现可展开）；展开时仅 hover 显示。
    private var chevronVisible: Bool { isCollapsed || hovered }
    private var hasError: Bool { account.services.contains { $0.status == .error } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .padding(.horizontal, 16)

            if isCollapsed {
                collapsedCard
                    .padding(.horizontal, 12)
            } else {
                ForEach(account.services) { service in
                    ServiceCardView(service: service, account: account, model: model)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.crop.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(account.accountDisplayName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if account.authMethod == .web {
                Text(webBadgeText)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(webBadgeExpired ? Color.orange : Color.secondary)
                    .help(webBadgeExpired
                          ? "网页登录已过期，点击右侧重新授权"
                          : "网页登录账号（免 AK/SK），refresh token 48 小时有效，到期需重新授权一次")
            }
            if isCollapsed && hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
                    .help("该账号有服务刷新失败，展开查看详情")
            }
            Spacer()
            if account.webReauthNeeded {
                Button {
                    showReauth = true
                } label: {
                    Label("重新授权", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.orange)
                .help("网页登录已过期，点击重新授权")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggleAccountCollapsed(account.id) }
        .sheet(isPresented: $showReauth) {
            WebReauthorizeSheet(model: model, accountID: account.id)
        }
        .onHover { hovered = $0 }
        .help(isCollapsed ? "点击展开账号" : "点击折叠账号")
        // chevron 浮在左侧边距里，不占排版空间：账号名始终在最左。
        .overlay(alignment: .leading) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .offset(x: -16)
                .allowsHitTesting(false)
                .opacity(chevronVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: chevronVisible)
        }
    }

    /// 折叠态摘要小卡：一个套餐/服务占一行，信息与展开态同源。
    private var collapsedCard: some View {
        let groups = SummaryBuilder.serviceGroups(for: account)
        return VStack(alignment: .leading, spacing: 6) {
            if groups.isEmpty {
                Text("暂无可显示的额度")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(groups) { group in
                    ServiceSummaryRow(symbol: group.symbol, metrics: group.metrics)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .opacity(hasError ? 0.7 : 1)
    }

    /// 账号层只标识登录方式与有效期，不显示任何套餐档位（tier 属于 Agent Plan 服务卡）。
    private var webBadgeExpired: Bool {
        account.webReauthNeeded ||
        (account.webTokenExpiresAt.map { $0.timeIntervalSinceNow <= 0 } ?? false)
    }

    private var webBadgeText: String {
        if webBadgeExpired { return "网页登录 · 需重新授权" }
        guard let exp = account.webTokenExpiresAt else { return "网页登录" }
        let remain = exp.timeIntervalSinceNow
        if remain >= 10 * 3600 {
            // 10 小时及以上显示整数，避免小数位干扰。
            return "网页登录 · 剩 \(Int(remain / 3600)) 小时"
        } else if remain >= 3600 {
            // 10 小时以内显示一位小数（如 9.3 小时），临期更精确。
            return String(format: "网页登录 · 剩 %.1f 小时", remain / 3600)
        } else if remain >= 60 {
            // 不足 1 小时直接整数分钟。
            return "网页登录 · 剩 \(Int(remain / 60)) 分钟"
        }
        return "网页登录 · 即将过期"
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
    @State private var hovered = false

    /// 所有服务卡（Agent Plan / Coding Plan / 语音）统一支持折叠。
    private var isCollapsed: Bool {
        model.isServiceCollapsed(accountID: account.id, serviceID: service.id)
    }
    /// chevron：折叠时常显；展开时仅 hover 卡片显示。
    private var chevronVisible: Bool { isCollapsed || hovered }

    var body: some View {
        // 卡片内容（标题行 + 服务详情 + 错误信息）。
        let content = VStack(alignment: .leading, spacing: 8) {
            titleRow

            if isCollapsed {
                // 任何服务折叠后都收成同一形态的一行带色摘要（无数据的错误卡为空提示）。
                if SummaryBuilder.metrics(for: service).isEmpty {
                    Text("暂无可显示的额度")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    QuotaSummaryLine(metrics: SummaryBuilder.metrics(for: service))
                }
            } else {
                switch service.content {
                case .agentPlan(let plan):
                    PlanCardView(periods: plan.periods.map { PlanPeriodDisplay.agent($0, unit: plan.unit) },
                                 account: account, service: service, model: model)
                case .codingPlan(let plan):
                    PlanCardView(periods: plan.periods.map { PlanPeriodDisplay.coding($0) },
                                 account: account, service: service, model: model)
                case .speech(let pack):
                    SpeechCardView(pack: pack, compact: model.agentPlanCompactLayout)
                }
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
        .onHover { hovered = $0 }

        // 语音服务：整张 service 卡片是 1 个指标 → 整张可点击钉选。
        // 折叠态不显示钉选热区（要钉指标先展开），与套餐卡行为一致。
        // Agent Plan / Coding Plan：每个 period 各自是 1 个指标 → 在 PlanCardView 里逐行套 menuBarPinRow。
        if case .speech(let pack) = service.content,
           !pack.purchased.isEmpty, !isCollapsed {
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
    /// Agent Plan 标题行最左有折叠 chevron（hover 显示 / 折叠常显），整行可点折叠。
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
            // 语音标题行右侧的大「剩 X%」：标准样式、展开态显示（原样）；折叠后由摘要行承担不重复；
            // 紧凑样式下移到进度条行内，标题行不重复。
            if case .speech(let pack) = service.content,
               !pack.purchased.isEmpty, !isCollapsed,
               !model.agentPlanCompactLayout {
                Text("剩 \(Formatting.percent(pack.remainingPercent))%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuotaColor.bar(pack.remainingPercent))
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.toggleServiceCollapsed(accountID: account.id, serviceID: service.id)
        }
        .help(isCollapsed ? "点击展开服务详情" : "点击折叠为摘要")
        // chevron 浮在卡片左边距里，不占排版空间：服务名/进度条始终与最左对齐。
        .overlay(alignment: .leading) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                    .offset(x: -24)
                    .allowsHitTesting(false)
                    .opacity(chevronVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: chevronVisible)
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
