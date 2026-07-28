import AppKit
import SwiftUI

struct PopoverView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if model.visibleAccounts.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.visibleAccounts) { account in
                        AccountSectionView(account: account)
                    }
                }
                .padding(.vertical, 12)
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("My Quota Bar")
                .font(.headline)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let last = model.lastRefreshAt {
                Text(RelativeTime.string(from: last))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(model.isRefreshing ? "正在读取额度…" : "暂无可显示的服务")
                .font(.title3)
                .foregroundStyle(.secondary)
            if !model.isRefreshing {
                Text("在设置里添加账号、填入 AK/SK，并选择要看的服务")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 90)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button("设置") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button("刷新") { model.refresh() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.isRefreshing)

            Spacer()

            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 相对时间

enum RelativeTime {
    static func string(from date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "刚刚更新" }
        if secs < 3600 { return "\(secs / 60) 分钟前" }
        return "\(secs / 3600) 小时前"
    }
}
