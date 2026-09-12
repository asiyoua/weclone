import SwiftUI
import Cocoa

struct DashboardView: View {
    @ObservedObject var weChatManager: WeChatManager
    @ObservedObject var autoUpdate: AutoUpdateController

    private enum Page: String, CaseIterable, Identifiable {
        case overview, accounts, maintenance, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "总览"
            case .accounts: return "账号"
            case .maintenance: return "维护"
            case .about: return "关于"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: return "gauge"
            case .accounts: return "person.crop.circle"
            case .maintenance: return "wrench.and.screwdriver"
            case .about: return "info.circle"
            }
        }

        // 仿 macOS 系统设置图标的渐变芯片配色
        var chipColors: [Color] {
            switch self {
            case .overview: return [Color(red: 0.36, green: 0.66, blue: 0.96), Color(red: 0.12, green: 0.44, blue: 0.89)]
            case .accounts: return [Color(red: 0.67, green: 0.56, blue: 0.95), Color(red: 0.45, green: 0.31, blue: 0.81)]
            case .maintenance: return [Color(red: 0.64, green: 0.66, blue: 0.69), Color(red: 0.42, green: 0.45, blue: 0.49)]
            case .about: return [Color(red: 0.39, green: 0.78, blue: 0.47), Color(red: 0.18, green: 0.62, blue: 0.32)]
            }
        }
    }

    @State private var selectedPage: Page = .overview
    @State private var targetCount: String = "2"
    @State private var keepCloneCount: String = "1"
    @State private var feedbackMessage: String = ""
    @State private var conflictPaths: [String] = []
    @State private var accountRows: [WeChatManager.InstanceStoragePath] = []
    @State private var aliasInputs: [String: String] = [:]
    @State private var isBusy: Bool = false
    @State private var isLoadingAccounts: Bool = false
    @State private var pendingSyncBundleIds: Set<String> = []
    /// 各实例聊天数据目录的磁盘占用（字节），会话内缓存
    @State private var storageSizes: [String: Int64] = [:]
    @State private var sizeScansInProgress: Set<String> = []
    @State private var showOnboarding: Bool = false
    @State private var showResetConfirmation: Bool = false
    @AppStorage("weclone.onboarding_dismissed") private var onboardingDismissed = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            contentArea
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            let state = weChatManager.resolveFirstRunState()
            if state.isFirstRun || !onboardingDismissed {
                showOnboarding = true
            }
            conflictPaths = state.duplicateAppPaths
            refreshAccountRows()
        }
        .onChange(of: selectedPage) { page in
            if page == .accounts {
                refreshAccountRows()
            }
        }
        .sheet(isPresented: $showOnboarding, onDismiss: {
            onboardingDismissed = true
        }) {
            OnboardingView(dismiss: { showOnboarding = false })
        }
        .confirmationDialog(
            "重置设置",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("重置", role: .destructive) {
                feedbackMessage = weChatManager.resetLocalMappingsForExport()
                refreshAccountRows()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空名称和账号记忆，不会删除微信数据。")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Page.allCases) { page in
                sidebarButton(page)
            }
            Spacer()
            Text("WeClone v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .frame(width: 190)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sidebarButton(_ page: Page) -> some View {
        let selected = selectedPage == page
        let chip = LinearGradient(
            colors: page.chipColors,
            startPoint: .topLeading, endPoint: .bottomTrailing)
        return Button {
            selectedPage = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(page.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                selected ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            // 整行都可点击（否则透明背景区域点击会穿透）
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .foregroundColor(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Content

    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(selectedPage.title)
                    .font(.title2.bold())
                pageContent
                feedbackBar
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedPage {
        case .overview:
            overviewPage
        case .accounts:
            accountsPage
        case .maintenance:
            maintenancePage
        case .about:
            aboutPage
        }
    }

    // MARK: 总览

    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !conflictPaths.isEmpty {
                conflictWarning
            }
            if !onboardingDismissed {
                welcomeBanner
            }
            settingsGroup(title: "运行状态") {
                runningStatusRows
            }
            settingsGroup(title: "快捷操作") {
                quickActionRows
            }
        }
    }

    @ViewBuilder
    private var conflictWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("检测到旧版本 WeClone，建议只保留一个：", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.orange)
            ForEach(conflictPaths, id: \.self) { path in
                Text(path)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var welcomeBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("三步开始使用")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: { withAnimation(.easeOut) { onboardingDismissed = true } }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("点击「再开一个」启动第二个微信", systemImage: "1.circle.fill")
                Label("用另一个手机扫码登录", systemImage: "2.circle.fill")
                Label("到「账号」页点击「记住当前账号」，下次自动对应", systemImage: "3.circle.fill")
            }
            .font(.system(size: 12))
            .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var runningStatusRows: some View {
        let summaries = weChatManager.runningSummaries
        if summaries.isEmpty {
            settingsRow(label: "当前状态", subtitle: "暂无微信运行", divider: false) {
                Circle()
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
            }
        } else {
            settingsRow(label: "正在运行 \(summaries.count) 个微信", divider: true) {
                EmptyView()
            }
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(summaries) { item in
                            instanceCard(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func instanceCard(_ item: WeChatManager.RunningInstanceSummary) -> some View {
        let state = bindingState(active: item.activeWxid, expected: item.expectedWxid)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(state.color)
                    .frame(width: 6, height: 6)
                Text(item.displayName)
                    .font(.system(size: 13, weight: .medium))
            }
            if let active = item.activeWxid, !active.isEmpty {
                Text(shortWxid(active))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Text(instanceTypeLabel(item.bundleIdentifier))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text(state.pillText)
                .font(.system(size: 10))
                .foregroundColor(state.color)
        }
        .padding(10)
        .frame(minWidth: 130, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var quickActionRows: some View {
        settingsRow(label: "启动新实例", subtitle: "自动创建或复用微信副本，多开不串号", divider: true) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: { launchOneMore() }) {
                    Label("再开一个", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)

                Button(action: {
                    runBusy { weChatManager.closeAllWeChat(); return "已请求关闭所有微信。" }
                }) {
                    Label("全部关闭", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isBusy)
            }
        }
        settingsRow(label: "同时开多个", subtitle: "自动补充到指定数量", divider: false) {
            HStack(spacing: 6) {
                TextField("2", text: $targetCount)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .multilineTextAlignment(.center)
                Text("个微信")
                    .foregroundColor(.secondary)
                Button("开始") {
                    launchUpToTarget()
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }
        }
    }

    // MARK: 账号

    /// 窗口与账号对应关系的五种状态，卡片据此显示颜色、说明句和主按钮
    private enum AccountCardState {
        case consistent       // 已记住且一致
        case mismatch         // 已记住但当前登录的不是它
        case unboundLoggedIn  // 登录了但还没记住
        case expectedOnly     // 记住了但没检测到登录
        case unknown          // 都没有

        var color: Color {
            switch self {
            case .consistent: return .green
            case .mismatch: return .red
            case .unboundLoggedIn: return .orange
            case .expectedOnly, .unknown: return .gray
            }
        }

        var pillText: String {
            switch self {
            case .consistent: return "已记住"
            case .mismatch: return "账号对不上"
            case .unboundLoggedIn: return "未记住"
            case .expectedOnly, .unknown: return "未登录"
            }
        }
    }

    private var accountsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("这里的每一行对应一个微信窗口（主程序或副本）。给窗口起好名字、记住它登录的账号，之后多开就会自动对上，不会串号。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            settingsGroup(title: "批量操作") {
                settingsRow(label: "记住所有运行中的账号", subtitle: "不想逐个窗口点时，一键记住每个窗口当前登录的账号", divider: true) {
                    Button("执行") {
                        runBusy(
                            { weChatManager.autoBindRunningInstances(limit: 4) },
                            completion: { refreshAccountRows() }
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }
                settingsRow(label: "按账号重启", subtitle: "关闭全部微信，再按记住的对应关系逐个开回来", divider: false) {
                    Button("执行") {
                        runBusy { weChatManager.relaunchByBindings() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                }
            }

            HStack(spacing: 8) {
                Text("微信窗口（\(accountRows.count)）")
                    .font(.system(size: 13, weight: .semibold))
                if isLoadingAccounts {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button {
                    refreshAccountRows()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isLoadingAccounts)
            }
            .padding(.top, 6)

            if accountRows.isEmpty {
                emptyAccountsCard
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(accountRows.enumerated()), id: \.element.bundleIdentifier) { index, item in
                        accountCard(item, index: index)
                    }
                }
            }
        }
    }

    private var emptyAccountsCard: some View {
        VStack(spacing: 6) {
            Text(isLoadingAccounts ? "正在扫描数据目录……" : "还没有可显示的微信窗口")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            if !isLoadingAccounts {
                Text("去「总览」点「再开一个」，创建第一个微信副本。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func accountCard(_ item: WeChatManager.InstanceStoragePath, index: Int) -> some View {
        let state = bindingState(active: item.activeWxid, expected: item.expectedWxid)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.color)
                    .frame(width: 8, height: 8)
                TextField("窗口名称", text: aliasBinding(item))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 130, alignment: .leading)
                    .onSubmit { saveAlias(item) }
                if isAliasDirty(item) {
                    Button("保存") { saveAlias(item) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
                Text("· \(instanceTypeLabel(item.bundleIdentifier))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if pendingSyncBundleIds.contains(item.bundleIdentifier) {
                    Text("待同步")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .help("微信更新过，下次启动这个副本时会自动重建，需要完整复制、耗时较长")
                }
                Spacer()
                statusPill(state)
                cardMenu(item, index: index)
            }

            HStack(spacing: 10) {
                Text(accountSentence(item, state: state))
                    .font(.system(size: 11))
                    .foregroundColor(state == .mismatch ? .red : .secondary)
                Spacer(minLength: 0)
                if state == .mismatch, let active = item.activeWxid {
                    Button("更新绑定") {
                        bindCard(item, index: index, wxid: active)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isBusy)
                }
                if state == .unboundLoggedIn, let active = item.activeWxid {
                    Button("记住当前账号") {
                        bindCard(item, index: index, wxid: active)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)
                }
            }

            HStack(spacing: 8) {
                Text(item.wechatFilesPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(item.wechatFilesPath)
                Spacer(minLength: 8)
                storageSizeLabel(item)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func statusPill(_ state: AccountCardState) -> some View {
        Text(state.pillText)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(state.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(state.color.opacity(0.12), in: Capsule())
    }

    private func cardMenu(_ item: WeChatManager.InstanceStoragePath, index: Int) -> some View {
        Menu {
            Button("在访达中显示") {
                openInFinder(path: item.wechatFilesPath, exists: item.wechatFilesExists)
            }
            Button("复制数据目录路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.wechatFilesPath, forType: .string)
                feedbackMessage = "路径已复制。"
            }
            if isInstanceRunning(item.bundleIdentifier) {
                Divider()
                Button("退出此微信") {
                    weChatManager.closeWeChatInstance(bundleId: item.bundleIdentifier)
                    feedbackMessage = "\(item.appName)：已请求退出。"
                }
            }
            if !(item.expectedWxid ?? "").isEmpty {
                Divider()
                Button("取消记住") {
                    weChatManager.bindExpectedWxid(nil, for: item.bundleIdentifier)
                    accountRows[index] = updatedRow(item, expectedWxid: nil)
                    feedbackMessage = "\(item.appName)：已取消记住"
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func accountSentence(_ item: WeChatManager.InstanceStoragePath, state: AccountCardState) -> String {
        let active = item.activeWxid ?? ""
        let expected = item.expectedWxid ?? ""
        switch state {
        case .consistent:
            return "这个窗口登录的就是记住的账号（\(shortWxid(active))），对应关系正常。"
        case .mismatch:
            return "记住的是 \(shortWxid(expected))，这个窗口现在登录的是 \(shortWxid(active))。"
        case .unboundLoggedIn:
            return "这个窗口登录了 \(shortWxid(active))，还没记住对应关系。"
        case .expectedOnly:
            return "已记住 \(shortWxid(expected))；暂时没检测到登录账号，打开微信进入主界面后会自动核对。"
        case .unknown:
            return "没检测到登录账号，也没记住过对应关系。"
        }
    }

    private func isInstanceRunning(_ bundleId: String) -> Bool {
        weChatManager.runningSummaries.contains { $0.bundleIdentifier == bundleId }
    }

    private func bindCard(_ item: WeChatManager.InstanceStoragePath, index: Int, wxid: String) {
        weChatManager.bindExpectedWxid(wxid, for: item.bundleIdentifier)
        accountRows[index] = updatedRow(item, expectedWxid: wxid)
        feedbackMessage = "\(item.appName)：已记住 \(shortWxid(wxid))"
    }

    private func bindingState(active: String?, expected: String?) -> AccountCardState {
        let hasActive = !(active ?? "").isEmpty
        let hasExpected = !(expected ?? "").isEmpty
        if hasExpected && hasActive {
            return active == expected ? .consistent : .mismatch
        }
        if hasExpected { return .expectedOnly }
        if hasActive { return .unboundLoggedIn }
        return .unknown
    }

    private func shortWxid(_ wxid: String?) -> String {
        guard let wxid, !wxid.isEmpty else { return "（无）" }
        guard wxid.count > 12 else { return wxid }
        return "\(wxid.prefix(6))…\(wxid.suffix(4))"
    }

    private func instanceTypeLabel(_ bundleId: String) -> String {
        if bundleId == "com.tencent.xinWeChat" { return "微信主程序" }
        let prefix = "com.tencent.xinWeChat.multi"
        if bundleId.hasPrefix(prefix), let n = Int(bundleId.dropFirst(prefix.count)) {
            return "微信副本 \(n)"
        }
        return bundleId
    }

    private func aliasBinding(_ item: WeChatManager.InstanceStoragePath) -> Binding<String> {
        Binding(
            get: { aliasInputs[item.bundleIdentifier] ?? item.appName },
            set: { aliasInputs[item.bundleIdentifier] = $0 }
        )
    }

    private func isAliasDirty(_ item: WeChatManager.InstanceStoragePath) -> Bool {
        (aliasInputs[item.bundleIdentifier] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines) != item.appName
    }

    private func saveAlias(_ item: WeChatManager.InstanceStoragePath) {
        let alias = (aliasInputs[item.bundleIdentifier] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        weChatManager.setInstanceDisplayName(alias, for: item.bundleIdentifier)
        aliasInputs[item.bundleIdentifier] = alias
        feedbackMessage = "名称已保存。"
        refreshAccountRows()
    }

    // MARK: 维护

    private var maintenancePage: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(title: "副本清理") {
                settingsRow(label: "清理旧副本", subtitle: "只保留最近使用的若干个微信副本，运行中的不会被动", divider: false) {
                    HStack(spacing: 6) {
                        Text("保留最近")
                            .foregroundColor(.secondary)
                        TextField("1", text: $keepCloneCount)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 36)
                            .multilineTextAlignment(.center)
                        Text("个")
                            .foregroundColor(.secondary)
                        Button("清理") {
                            cleanupClones()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                    }
                }
            }

            settingsGroup(title: "偏好设置") {
                settingsRow(label: "串号提醒", subtitle: "微信窗口登录的账号和记住的对不上时，发系统通知提醒", divider: false) {
                    Toggle("", isOn: $weChatManager.mismatchAlertEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            settingsGroup(title: "安全操作") {
                settingsRow(label: "重置设置", subtitle: "清空实例名称与账号记忆，不动微信数据", divider: true) {
                    Button("重置", role: .destructive) {
                        showResetConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }
                settingsRow(label: "撤销上一步", subtitle: "撤销最近一次重置或清理（可恢复废纸篓项目）", divider: true) {
                    Button("撤销") {
                        feedbackMessage = weChatManager.undoLastOperation()
                        refreshAccountRows()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!weChatManager.canUndoLastAction || isBusy)
                }
                settingsRow(label: "复制诊断", subtitle: "导出运行状态与目录信息，便于排查问题", divider: false) {
                    Button("复制") {
                        runBusy { weChatManager.copyDiagnosticsToPasteboard() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }
            }
        }
    }

    // MARK: 关于

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                BrandLogoView(size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("WeClone")
                        .font(.system(size: 22, weight: .bold))
                    Text("稳定多开 · 账号不串 · 数据不丢")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 4)

            settingsGroup(title: "应用信息") {
                settingsRow(label: "版本", divider: true) {
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"))")
                        .foregroundColor(.secondary)
                }
                settingsRow(label: "系统要求", subtitle: "微信多开依赖本机已安装微信", divider: true) {
                    Text("macOS 13.0+")
                        .foregroundColor(.secondary)
                }
                settingsRow(label: "数据位置", subtitle: "微信副本与数据目录均在本用户目录下，卸载即清理", divider: false) {
                    Text("~/Applications/WeCloneClones")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            settingsGroup(title: "三步开始") {
                settingsRow(label: "再开一个微信", subtitle: "在「总览」点击「再开一个」，自动创建第二个微信窗口", divider: true) {
                    Text("1")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.accentColor))
                }
                settingsRow(label: "扫码登录", subtitle: "用另一个手机微信扫码登录第二个账号", divider: true) {
                    Text("2")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.accentColor))
                }
                settingsRow(label: "记住账号", subtitle: "在「账号」页绑定后，下次启动自动对应，不会串号", divider: false) {
                    Text("3")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.accentColor))
                }
            }

            settingsGroup(title: "软件更新") {
                settingsRow(label: "检查更新", subtitle: autoUpdate.statusText, divider: true) {
                    HStack(spacing: 8) {
                        if autoUpdate.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("立即检查") {
                            autoUpdate.checkNow()
                        }
                        .buttonStyle(.bordered)
                        .disabled(autoUpdate.isChecking)
                    }
                }
                settingsRow(label: "自动检查更新", subtitle: "每天自动检查一次，发现新版本先询问再安装", divider: false) {
                    Toggle("", isOn: $autoUpdate.autoUpdateEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }

    // MARK: - Feedback

    @ViewBuilder
    private var feedbackBar: some View {
        if !feedbackMessage.isEmpty {
            let isNegative = feedbackMessage.contains("失败") || feedbackMessage.contains("对不上")
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: isNegative ? "exclamationmark.circle.fill" : "info.circle")
                    .foregroundColor(isNegative ? .orange : .secondary)
                    .font(.system(size: 12))
                Text(feedbackMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        if !weChatManager.lastOperationMessage.isEmpty && feedbackMessage.isEmpty {
            Text(weChatManager.lastOperationMessage)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Actions

    /// 耗时操作放后台线程执行，避免首次克隆微信副本时界面卡死；completion 在主线程回调
    private func runBusy(_ work: @escaping () -> String, completion: (() -> Void)? = nil) {
        isBusy = true
        feedbackMessage = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                feedbackMessage = result
                isBusy = false
                weChatManager.refreshSummariesNow()
                completion?()
            }
        }
    }

    private func launchOneMore() {
        runBusy {
            weChatManager.launchNewWeChat()
                ? "已发起启动新的微信实例。"
                : "启动失败：未找到微信应用或副本创建失败。"
        }
    }

    private func launchUpToTarget() {
        guard let count = Int(targetCount), count > 0 else {
            feedbackMessage = "请输入有效的微信数量。"
            return
        }
        runBusy { weChatManager.launchWeChatUpTo(count); return "已启动到 \(count) 个微信。" }
    }

    private func cleanupClones() {
        guard let keep = Int(keepCloneCount), keep >= 0 else {
            feedbackMessage = "请输入有效的保留数量。"
            return
        }
        runBusy {
            let result = weChatManager.cleanupClones(keepRecentCount: keep)
            return "已清理 \(result.deletedPaths.count) 个副本，保留 \(result.kept) 个，跳过 \(result.skippedRunning) 个运行中的。"
        }
    }

    /// 后台扫描数据目录，避免主线程磁盘 I/O
    private func refreshAccountRows() {
        isLoadingAccounts = true
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = weChatManager.getInstanceStoragePaths()
            let pendingSync = Set(
                rows.map { $0.bundleIdentifier }
                    .filter { weChatManager.cloneNeedsSync(bundleId: $0) })
            DispatchQueue.main.async {
                accountRows = rows
                pendingSyncBundleIds = pendingSync
                for row in rows where aliasInputs[row.bundleIdentifier] == nil {
                    aliasInputs[row.bundleIdentifier] = row.appName
                }
                isLoadingAccounts = false
                scanStorageSizes(for: rows)
            }
        }
    }

    /// 逐个实例后台统计数据目录体积；进行中的实例不重复扫，已有缓存值先展示旧值
    private func scanStorageSizes(for rows: [WeChatManager.InstanceStoragePath]) {
        for row in rows where row.wechatFilesExists {
            let bundleId = row.bundleIdentifier
            guard !sizeScansInProgress.contains(bundleId) else { continue }
            sizeScansInProgress.insert(bundleId)
            let target = row.wechatFilesPath
            DispatchQueue.global(qos: .utility).async {
                let size = weChatManager.directorySize(target)
                DispatchQueue.main.async {
                    if let size {
                        storageSizes[bundleId] = size
                    }
                    sizeScansInProgress.remove(bundleId)
                }
            }
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 路径行尾部的数据体积胶囊
    @ViewBuilder
    private func storageSizeLabel(_ item: WeChatManager.InstanceStoragePath) -> some View {
        if item.wechatFilesExists {
            if let size = storageSizes[item.bundleIdentifier] {
                Text("数据 \(formattedSize(size))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                    .help("该窗口聊天数据目录的磁盘占用")
            } else if sizeScansInProgress.contains(item.bundleIdentifier) {
                Text("统计中…")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
        }
    }

    private func updatedRow(_ old: WeChatManager.InstanceStoragePath, expectedWxid: String?) -> WeChatManager.InstanceStoragePath {
        let active = old.activeWxid
        let status: String
        if let expected = expectedWxid, !expected.isEmpty {
            if let active, active == expected {
                status = "账号和绑定一致"
            } else if let active {
                status = "账号和绑定不一致：当前 \(active) / 绑定 \(expected)"
            } else {
                status = "未识别到当前账号（期望 \(expected)）"
            }
        } else if let active, !active.isEmpty {
            status = "未绑定（当前账号 \(active)）"
        } else {
            status = "未绑定且未识别账号"
        }
        return WeChatManager.InstanceStoragePath(
            appName: old.appName,
            bundleIdentifier: old.bundleIdentifier,
            containerPath: old.containerPath,
            exists: old.exists,
            wechatFilesPath: old.wechatFilesPath,
            wechatFilesExists: old.wechatFilesExists,
            activeWxid: old.activeWxid,
            wxidCount: old.wxidCount,
            expectedWxid: expectedWxid,
            bindingStatus: status
        )
    }

    private func openInFinder(path: String, exists: Bool) {
        let targetPath = exists ? path : "\(NSHomeDirectory())/Library/Containers"
        let targetURL = URL(fileURLWithPath: targetPath, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
    }

    // MARK: - Components（Pico 同款分组样式）

    /// 设置行：左侧标题（可选副标题），右侧控件，行底细分隔线
    private func settingsRow<Control: View>(
        label: String,
        subtitle: String? = nil,
        divider: Bool,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if divider {
                Divider().padding(.leading, 16)
            }
        }
    }

    /// 分组卡片：组标题 + 圆角细描边容器
    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
    }
}
