import AppKit
import SwiftUI
import NineBarCore

public struct SettingsView: View {
    @ObservedObject private var model: RadarViewModel
    private let onEditWatchlist: @MainActor () -> Void

    public init(model: RadarViewModel, onEditWatchlist: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.onEditWatchlist = onEditWatchlist
    }

    public var body: some View {
        Form {
            languageSection
            monitoringSection
            notificationsSection
            watchlistSection
            loginSection
            maintenanceSection
            diagnosticsSection
            errorSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 650)
        // Rebuild every row when the language changes.
        .id(model.settings.language)
        .task { await model.prepareSettings() }
    }

    private var languageSection: some View {
        Section(L10n.t("语言", "Language")) {
            // Both names stay visible so the option can be found in either language.
            Picker("语言 / Language", selection: Binding(
                get: { model.settings.language },
                set: { language in Task { await model.setLanguage(language) } }
            )) {
                Text(L10n.t("跟随系统", "System")).tag(AppLanguage.system)
                Text("简体中文").tag(AppLanguage.simplifiedChinese)
                Text("English").tag(AppLanguage.english)
            }
            Text(L10n.t(
                "Finder 和通知横幅中的应用名称跟随系统语言。",
                "The app name in Finder and notification banners follows the system language."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var monitoringSection: some View {
        Section(L10n.t("监控周期", "Timeframes")) {
            Toggle(L10n.t("1分钟", "1 minute"), isOn: Binding(
                get: { model.settings.enabledTimeframes.contains(.oneMinute) },
                set: { enabled in Task { await model.setTimeframe(.oneMinute, enabled: enabled) } }
            ))
            Toggle(L10n.t("5分钟", "5 minutes"), isOn: Binding(
                get: { model.settings.enabledTimeframes.contains(.fiveMinutes) },
                set: { enabled in Task { await model.setTimeframe(.fiveMinutes, enabled: enabled) } }
            ))
        }
    }

    private var notificationsSection: some View {
        Section(L10n.t("通知", "Notifications")) {
            Toggle(L10n.t("第8根提醒", "Alert at bar 8"), isOn: Binding(
                get: { model.settings.notifyAtEight },
                set: { enabled in Task { await model.setNotificationAtEight(enabled) } }
            ))
            Toggle(L10n.t("第9根确认提醒", "Alert when bar 9 confirms"), isOn: Binding(
                get: { model.settings.notifyAtNine },
                set: { enabled in Task { await model.setNotificationAtNine(enabled) } }
            ))
            Toggle(L10n.t("第9根播放系统声音", "Play a sound at bar 9"), isOn: Binding(
                get: { model.settings.soundAtNine },
                set: { enabled in Task { await model.setSoundAtNine(enabled) } }
            ))
            .disabled(!model.settings.notifyAtNine)

            HStack {
                Text(L10n.t("系统通知权限", "Notification permission"))
                Spacer()
                Text(notificationStatusText)
                    .foregroundStyle(.secondary)
                Button(L10n.t("请求权限", "Request")) {
                    Task { await model.requestNotificationAuthorization() }
                }
            }
        }
    }

    private var watchlistSection: some View {
        Section(L10n.t("自选股", "Watchlist")) {
            HStack {
                Text(L10n.t(
                    "正在监控 \(model.state.watchlist.count) 只",
                    "Monitoring \(model.state.watchlist.count) symbols"
                ))
                Spacer()
                Button(L10n.t("编辑…", "Edit…")) { onEditWatchlist() }
            }
            Text(L10n.t(
                "支持沪深 A 股和场内 ETF，不支持北交所、LOF、可转债和港股。",
                "Shanghai and Shenzhen A-shares and ETFs are supported. Beijing Stock Exchange, LOFs, convertible bonds and Hong Kong stocks are not."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var loginSection: some View {
        Section(L10n.t("登录启动", "Launch at login")) {
            Toggle(L10n.t("登录时启动九转雷达", "Open NineBar at login"), isOn: Binding(
                get: { model.loginLaunchToggleIsOn },
                set: { enabled in Task { await model.setStartAtLogin(enabled) } }
            ))
            HStack {
                Text(L10n.t("系统状态", "System status"))
                Spacer()
                Text(loginStatusText)
                    .foregroundStyle(.secondary)
                if model.loginItemStatus == .requiresApproval {
                    Button(L10n.t("打开登录项设置", "Open Login Items")) {
                        Task { await model.openLoginItemsSettings() }
                    }
                }
            }
        }
    }

    private var maintenanceSection: some View {
        Section(L10n.t("本地数据", "Local data")) {
            HStack {
                Text(L10n.t("数据库与日志", "Database and logs"))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: model.storageUsageBytes, countStyle: .file))
                    .foregroundStyle(.secondary)
                Button(L10n.t("刷新", "Refresh")) { Task { await model.refreshStorageUsage() } }
            }
            Button(L10n.t("清理30日前历史", "Clear history older than 30 trading days")) {
                Task { await model.clearExpiredHistory() }
            }
        }
    }

    private var diagnosticsSection: some View {
        Section(L10n.t("诊断", "Diagnostics")) {
            Button(L10n.t("复制诊断信息", "Copy diagnostics")) {
                Task {
                    let text = await model.diagnosticCopy()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            Text(L10n.t(
                "诊断信息不包含账户、文件路径、网址或原始行情内容。",
                "Diagnostics never include accounts, file paths, URLs or raw market data."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = model.settingsErrorMessage ?? model.watchlistErrorMessage {
            Section {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
    }

    private var notificationStatusText: String {
        switch model.notificationAuthorizationStatus {
        case .unknown: L10n.t("未确定", "Not determined")
        case .granted: L10n.t("已允许", "Allowed")
        case .denied: L10n.t("已拒绝", "Denied")
        }
    }

    private var loginStatusText: String {
        switch model.loginItemStatus {
        case .enabled: L10n.t("已启用", "On")
        case .disabled: L10n.t("未启用", "Off")
        case .requiresApproval: L10n.t("需要系统批准", "Needs approval")
        case .unavailable: L10n.t("不可用", "Unavailable")
        }
    }
}
