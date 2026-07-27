import SwiftUI

@main
@MainActor
struct MyQuotaBarApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
                .onAppear { model.refresh() }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: model.menuBarSymbol)
                    .imageScale(.small)
                Text(model.menuBarText)
                    .monospacedDigit()
            }
            .onAppear { model.startAutomaticRefresh() }
            .accessibilityLabel("My Quota Bar \(model.menuBarText)")
        }
        .menuBarExtraStyle(.window)

        // 独立设置窗口（方案 C）
        Window("My Quota Bar 设置", id: "settings") {
            SettingsWindow(model: model)
        }
        .windowResizability(.contentSize)
    }
}
