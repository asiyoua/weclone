import SwiftUI
import Cocoa
import Combine

struct DashboardView: View {
    @ObservedObject var weChatManager: WeChatManager
    @ObservedObject var autoUpdate: AutoUpdateController

    private enum Page: String, CaseIterable, Identifiable {
        case accounts, maintenance, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accounts: return "账号"
            case .maintenance: return "维护"
            case .about: return "关于"
            }
        }

        var systemImage: String {
            switch self {
            case .accounts: return "person.crop.circle"
            case .maintenance: return "wrench.and.screwdriver"
            case .about: return "info.circle"
            }
        }

        // 仿 macOS 系统设置图标的渐变芯片配色
        var chipColors: [Color] {
            switch self {
            case .accounts: return [Color(red: 0.67, green: 0.56, blue: 0.95), Color(red: 0.45, green: 0.31, blue: 0.81)]
            case .maintenance: return [Color(red: 0.64, green: 0.66, blue: 0.69), Color(red: 0.42, green: 0.45, blue: 0.49)]
            case .about: return [Color(red: 0.39, green: 0.78, blue: 0.47), Color(red: 0.18, green: 0.62, blue: 0.32)]
            }
        }
    }

    @State private var selectedPage: Page = .accounts
    @State private var targetCount: String = "2"
    @State private var keepCloneCount: String = "1"
    @State private var feedbackMessage: String = ""
    @State private var conflictPaths: [String] = []
    @State private var accountRows: [WeChatManager.InstanceStoragePath] = []
    @State private var aliasInputs: [String: String] = [:]
    @State private var isBusy: Bool = false
    @State private var isLoadingAccounts: Bool = false
    @State private var pendingSyncBundleIds: Set<String> = []
    @State private var lastRunningBundleIds: Set<String> = []
    @State private var deleteCandidate: WeChatManager.InstanceStoragePath?
    @State private var showDeleteConfirmation: Bool = false
    /// 各实例聊天数据目录的磁盘占用（字节），会话内缓存
    @State private var storageSizes: [String: Int64] = [:]
    @State private var sizeScansInProgress: Set<String> = []
    @State private var showOnboarding: Bool = false
    @State private var showResetConfirmation: Bool = false
    @State private var showRecloneConfirmation: Bool = false
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
        // 运行中的微信集合一变（重启、新开、退出）就重扫数据目录，登录状态不再停在旧值
        .onReceive(weChatManager.$runningSummaries) { summaries in
            let ids = Set(summaries.map { $0.bundleIdentifier })
            guard ids != lastRunningBundleIds else { return }
            lastRunningBundleIds = ids
            refreshAccountRows()
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
        .confirmationDialog(
            "删除「\(deleteCandidate?.appName ?? "")」",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除副本与数据目录", role: .destructive) {
                guard let item = deleteCandidate else { return }
                runBusy(
                    { weChatManager.deleteInstance(bundleId: item.bundleIdentifier) },
                    completion: { refreshAccountRows() }
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("把这个微信副本和它的聊天数据目录一起放进废纸篓（可撤销），并清掉记住的账号。微信主程序不受影响。")
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
        case .accounts:
            accountsPage
        case .maintenance:
            maintenancePage
        case .about:
            aboutPage
        }
    }

    // MARK: 账号（首页）

    private var accountsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !conflictPaths.isEmpty {
                conflictWarning
            }
            if !onboardingDismissed {
                welcomeBanner
            }

            settingsGroup(title: "账号操作") {
                settingsRow(label: "按账号重启（一键全开）", divider: true) {
                    Button("执行") {
                        runBusy(
                            { weChatManager.relaunchByBindings() },
                            completion: { refreshAccountRows() }
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                }
                settingsRow(label: "记住所有运行中的账号", divider: false) {
                    Button("执行") {
                        runBusy(
                            { weChatManager.autoBindRunningInstances(limit: 4) },
                            completion: { refreshAccountRows() }
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }
            }

            settingsGroup(title: "启动微信") {
                settingsRow(label: "启动新微信", divider: true) {
                    HStack(spacing: 8) {
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
                settingsRow(label: "同时开多个", divider: false) {
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

            HStack(spacing: 8) {
                Text("微信窗口（\(accountRows.count)）")
                    .font(.system(size: 13, weight: .semibold))
                if isLoadingAccounts && accountRows.isEmpty {
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
                Label("点「再开一个」启动第二个微信", systemImage: "1.circle.fill")
                Label("用另一个手机扫码登录", systemImage: "2.circle.fill")
                Label("点「记住所有运行中的账号」，下次一键全开自动对应", systemImage: "3.circle.fill")
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

    private var emptyAccountsCard: some View {
        VStack(spacing: 6) {
            Text(isLoadingAccounts ? "正在扫描数据目录……" : "还没有可显示的微信窗口")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            if !isLoadingAccounts {
                Text("点上方「再开一个」，创建第一个微信副本。")
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

    /// 窗口没运行时不显示登录态词汇，只说绑定本身
    private func displayPill(_ state: AccountCardState, isRunning: Bool) -> (text: String, color: Color) {
        if isRunning {
            return (state.pillText, state.color)
        }
        switch state {
        case .consistent, .expectedOnly:
            return ("已记住", .green)
        case .mismatch:
            return ("账号对不上", .red)
        case .unboundLoggedIn, .unknown:
            return ("未记住", .orange)
        }
    }

    private func accountCard(_ item: WeChatManager.InstanceStoragePath, index: Int) -> some View {
        let state = bindingState(active: item.activeWxid, expected: item.expectedWxid)
        let isRunning = isInstanceRunning(item.bundleIdentifier)
        let pill = item.unreadable
            ? (text: "无权限读取", color: Color.orange)
            : displayPill(state, isRunning: isRunning)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(pill.color)
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
                runningPill(isRunning: isRunning)
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
                statusPill(text: pill.text, color: pill.color)
                if item.bundleIdentifier != "com.tencent.xinWeChat" {
                    Button {
                        deleteCandidate = item
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isBusy)
                    .help("删除此窗口：副本与数据目录一起进废纸篓，可在维护页撤销")
                }
                cardMenu(item, index: index)
            }

            HStack(spacing: 10) {
                Text(accountSentence(item, state: state, isRunning: isRunning))
                    .font(.system(size: 11))
                    .foregroundColor(state == .mismatch ? .red : .secondary)
                Spacer(minLength: 0)
                if item.unreadable {
                    Button("去授权") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("打开系统设置的「完全磁盘访问权限」，把 WeClone 打开后回来点「刷新」")
                }
                if isRunning, state == .mismatch, let active = item.activeWxid {
                    Button("更新绑定") {
                        bindCard(item, index: index, wxid: active)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isBusy)
                }
                if isRunning, state == .unboundLoggedIn, let active = item.activeWxid {
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

    private func runningPill(isRunning: Bool) -> some View {
        let color: Color = isRunning ? .green : .secondary
        return Text(isRunning ? "运行中" : "未运行")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
    }

    private func statusPill(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func cardMenu(_ item: WeChatManager.InstanceStoragePath, index: Int) -> some View {
        Menu {
            Button("重启此微信") {
                runBusy(
                    { weChatManager.relaunchInstance(bundleId: item.bundleIdentifier) },
                    completion: { refreshAccountRows() }
                )
            }
            if isInstanceRunning(item.bundleIdentifier) {
                Button("退出此微信") {
                    weChatManager.closeWeChatInstance(bundleId: item.bundleIdentifier)
                    feedbackMessage = "\(item.appName)：已请求退出。"
                }
            }
            Divider()
            Button("在访达中显示") {
                openInFinder(path: item.wechatFilesPath, exists: item.wechatFilesExists)
            }
            Button("复制数据目录路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.wechatFilesPath, forType: .string)
                feedbackMessage = "路径已复制。"
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

    private func accountSentence(_ item: WeChatManager.InstanceStoragePath, state: AccountCardState, isRunning: Bool) -> String {
        let active = item.activeWxid ?? ""
        let expected = item.expectedWxid ?? ""
        if item.unreadable {
            return "WeClone 没有权限读取这个窗口的数据目录，认不了账号。点「去授权」，在完全磁盘访问权限里允许 WeClone 后回来刷新即可。"
        }
        if !isRunning {
            if !expected.isEmpty {
                return "窗口没有在运行。已记住 \(shortWxid(expected))，下次启动登录的就是这个账号。"
            }
            if !active.isEmpty {
                return "窗口没有在运行。上次登录的是 \(shortWxid(active))，还没记住对应关系。"
            }
            return "窗口没有在运行，也没记住过对应关系。"
        }
        switch state {
        case .consistent:
            return "这个窗口登录的就是记住的账号（\(shortWxid(active))），对应关系正常。"
        case .mismatch:
            return "记住的是 \(shortWxid(expected))，这个窗口现在登录的是 \(shortWxid(active))。"
        case .unboundLoggedIn:
            return "这个窗口登录了 \(shortWxid(active))，还没记住对应关系。"
        case .expectedOnly:
            return "已记住 \(shortWxid(expected))；正在登录或还没检测到账号，进入主界面后自动核对。"
        case .unknown:
            return "窗口开着但没检测到登录账号；如果停在扫码页，登录后自动更新。"
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
                settingsRow(label: "清理旧副本", divider: true) {
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
                settingsRow(label: "重建现有副本", divider: false) {
                    Button("重建") {
                        showRecloneConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }
                .confirmationDialog(
                    "重建现有副本",
                    isPresented: $showRecloneConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("重建", role: .destructive) {
                        runBusy { weChatManager.rebuildStoppedClones() }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("未运行的副本会被删除并用写时复制方式重建，账号数据不受影响。")
                }
            }

            settingsGroup(title: "偏好设置") {
                settingsRow(label: "串号提醒", divider: true) {
                    Toggle("", isOn: $weChatManager.mismatchAlertEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                settingsRow(label: "弹窗提醒更新", divider: true) {
                    Toggle("", isOn: $autoUpdate.autoUpdateEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                settingsRow(label: "自动安装更新", divider: false) {
                    Toggle("", isOn: $autoUpdate.autoInstallUpdates)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }

            settingsGroup(title: "安全操作") {
                settingsRow(label: "重置设置", divider: true) {
                    Button("重置", role: .destructive) {
                        showResetConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }
                settingsRow(label: "撤销上一步", divider: true) {
                    Button("撤销") {
                        feedbackMessage = weChatManager.undoLastOperation()
                        refreshAccountRows()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!weChatManager.canUndoLastAction || isBusy)
                }
                settingsRow(label: "复制诊断", divider: false) {
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
        VStack(spacing: 14) {
            BrandLogoView(size: 96)
            Text("WeClone")
                .font(.largeTitle.bold())
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")")
                .foregroundColor(.secondary)
            Text("一款稳定的微信多开工具。\n自动创建副本、记住账号，多开不串号、数据不丢。\n副本数据都在本机用户目录下。\n\nMIT 开源许可证")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button {
                autoUpdate.checkManually()
            } label: {
                if autoUpdate.isChecking {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("检查中……")
                    }
                } else {
                    Text("检查更新")
                }
            }
            .buttonStyle(.bordered)
            .disabled(autoUpdate.isBusy)
            if autoUpdate.hasStatus {
                Text(autoUpdate.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Divider()
            aboutLinkRow(
                label: "项目仓库",
                title: "github.com/asiyoua/weclone",
                urlString: "https://github.com/asiyoua/weclone")
            aboutLinkRow(
                label: "联系作者",
                title: "xinzhu400@gmail.com",
                urlString: "mailto:xinzhu400@gmail.com")
        }
        .padding(.top, 28)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
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
                ? "已发起启动新的微信。"
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

    /// 路径行尾部的数据体积胶囊（读不进去时不显示，避免误导成 0 KB）
    @ViewBuilder
    private func storageSizeLabel(_ item: WeChatManager.InstanceStoragePath) -> some View {
        if item.wechatFilesExists && !item.unreadable {
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
            bindingStatus: status,
            unreadable: old.unreadable
        )
    }

    private func openInFinder(path: String, exists: Bool) {
        let targetPath = exists ? path : "\(NSHomeDirectory())/Library/Containers"
        let targetURL = URL(fileURLWithPath: targetPath, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
    }

    // MARK: - Components（Pico 同款分组样式）

    /// 「关于」页链接行：左侧灰色小标签，右侧蓝色链接
    private func aboutLinkRow(label: String, title: String, urlString: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if let url = URL(string: urlString) {
                Link(title, destination: url)
                    .font(.caption)
            }
        }
    }

    /// 设置行：左侧标题，右侧控件，行底细分隔线
    private func settingsRow<Control: View>(
        label: String,
        divider: Bool,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 13))
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
