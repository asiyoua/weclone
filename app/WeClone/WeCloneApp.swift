import Cocoa
import SwiftUI
import Combine
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var statusMenu: NSMenu?
    var dashboardWindow: NSWindow?
    var weChatManager = WeChatManager()
    var autoUpdate: AutoUpdateController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        let updater = AutoUpdateController()
        autoUpdate = updater
        setupMenuBar()
        setupDashboardWindow(updater: updater)
        showDashboardWindow()
        startSummaryPolling()
        updater.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancellables.removeAll()
    }

    /// 运行态轮询统一走 WeChatManager（后台扫描、主线程发布），按钮随发布刷新
    private func startSummaryPolling() {
        weChatManager.startSummaryPolling()
        weChatManager.$runningSummaries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusButton()
            }
            .store(in: &cancellables)
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu = NSMenu()
        statusMenu?.delegate = self
        statusItem?.menu = statusMenu
        updateStatusButton()
        rebuildStatusMenu()
    }

    func setupDashboardWindow(updater: AutoUpdateController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WeClone"
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: DashboardView(weChatManager: weChatManager, autoUpdate: updater))
        hosting.sizingOptions = .minSize
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.setContentSize(NSSize(width: 820, height: 600))
        // macOS 26 的 window.center() 会把窗放到屏幕外且缩水，必须显式 setFrameOrigin
        centerDashboardWindow(on: window)
        dashboardWindow = window
    }

    /// 窗口小于内容最小尺寸说明被系统缩水，重新钉回标准尺寸并居中
    private func centerDashboardWindow(on window: NSWindow) {
        let size = NSSize(width: 820, height: 600)
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func showDashboardWindow() {
        if let window = dashboardWindow, window.frame.width < window.contentMinSize.width {
            centerDashboardWindow(on: window)
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildStatusMenu()
    }

    func updateStatusButton() {
        let summaries = weChatManager.runningSummaries
        let count = summaries.count
        if let button = statusItem?.button {
            button.title = count > 0 ? "W+ \(count)" : "W+"
            if summaries.isEmpty {
                button.toolTip = "WeClone"
            } else {
                button.toolTip = summaries.map {
                    let mark = $0.bindingStatus.contains("账号和绑定不一致") ? "⚠︎ " : ""
                    return "\(mark)\($0.displayName)：\($0.activeWxid.flatMap { weChatManager.shortWxid($0) } ?? "未识别账号")"
                }.joined(separator: "、")
            }
        }
    }

    func rebuildStatusMenu() {
        guard let menu = statusMenu else { return }
        menu.removeAllItems()

        // 只读轮询发布的缓存：主线程在这里做磁盘扫描曾把启动和开菜单卡死数分钟（TCC 重判定时无框可弹）
        let summaries = weChatManager.runningSummaries
        let infoTitle = summaries.isEmpty
            ? "暂无微信运行"
            : "运行中: " + summaries.map { $0.displayName }.joined(separator: "、")
        let infoItem = NSMenuItem(title: infoTitle, action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)

        if !summaries.isEmpty {
            for item in summaries {
                let status = item.bindingStatus.contains("账号和绑定不一致") ? " ⚠︎ 账号对不上" : ""
                let sub = NSMenuItem(title: "    \(item.displayName)：\(weChatManager.shortWxid(item.activeWxid))\(status)", action: nil, keyEquivalent: "")
                sub.isEnabled = false
                menu.addItem(sub)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // 按使用频率排：一键全开最高频，其次是启动类，记住/打开窗口次之，维护类垫底
        menu.addItem(NSMenuItem(title: "按账号重启（一键全开）", action: #selector(onRelaunchByBindings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "再开一个微信", action: #selector(onLaunchNewWeChat), keyEquivalent: "n"))

        let launchToItem = NSMenuItem(title: "同时开多个", action: nil, keyEquivalent: "")
        let launchSubmenu = NSMenu()
        [2, 3, 4].forEach { count in
            let item = NSMenuItem(title: "一共开 \(count) 个微信", action: #selector(onLaunchToCount(_:)), keyEquivalent: "")
            item.tag = count
            item.target = self
            launchSubmenu.addItem(item)
        }
        launchToItem.submenu = launchSubmenu
        menu.addItem(launchToItem)

        menu.addItem(NSMenuItem(title: "关闭全部微信", action: #selector(onCloseAllWeChat), keyEquivalent: "k"))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "记住所有运行中的账号", action: #selector(onBindTopTwoRunning), keyEquivalent: "b"))
        menu.addItem(NSMenuItem(title: "打开主窗口", action: #selector(onOpenDashboard), keyEquivalent: "d"))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "撤销上一步", action: #selector(onUndoLastAction), keyEquivalent: "z"))
        menu.items.last?.isEnabled = weChatManager.canUndoLastAction
        menu.addItem(NSMenuItem(title: "复制诊断信息", action: #selector(onCopyDiagnostics), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "重置设置", action: #selector(onResetMappings), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 WeClone", action: #selector(onQuitApp), keyEquivalent: "q"))

        updateStatusButton()
    }

    @objc func onLaunchNewWeChat() {
        _ = weChatManager.launchNewWeChat()
        updateStatusButton()
    }

    @objc func onLaunchToCount(_ sender: NSMenuItem) {
        weChatManager.launchWeChatUpTo(sender.tag)
        updateStatusButton()
    }

    @objc func onOpenDashboard() {
        showDashboardWindow()
    }

    @objc func onBindTopTwoRunning() {
        _ = weChatManager.autoBindRunningInstances(limit: 4)
        updateStatusButton()
    }

    @objc func onRelaunchByBindings() {
        // 关停再拉起全程带等待，放后台做，别把菜单栏卡住
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = self.weChatManager.relaunchByBindings()
            DispatchQueue.main.async {
                self.updateStatusButton()
            }
        }
    }

    @objc func onCloseAllWeChat() {
        weChatManager.closeAllWeChat()
        updateStatusButton()
    }

    @objc func onResetMappings() {
        let alert = NSAlert()
        alert.messageText = "重置设置"
        alert.informativeText = "将清空名称和账号记忆，不会删除微信数据。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            _ = weChatManager.resetLocalMappingsForExport()
            updateStatusButton()
        }
    }

    @objc func onUndoLastAction() {
        _ = weChatManager.undoLastOperation()
        updateStatusButton()
    }

    @objc func onCopyDiagnostics() {
        _ = weChatManager.copyDiagnosticsToPasteboard()
    }

    @objc func onQuitApp() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// 应用在前台时也以横幅形式展示串号提醒
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
