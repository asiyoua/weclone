import Foundation
import Cocoa
import UserNotifications

class WeChatManager: ObservableObject {
    struct FirstRunState {
        let isFirstRun: Bool
        let duplicateAppPaths: [String]
    }

    struct LaunchLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let displayName: String
        let bundleIdentifier: String
        let appPath: String
        let status: String
        let detail: String
    }

    struct RunningInstanceSummary: Identifiable {
        let id = UUID()
        let bundleIdentifier: String
        let displayName: String
        let activeWxid: String?
        let expectedWxid: String?
        let bindingStatus: String
    }

    struct InstanceStoragePath: Identifiable {
        let id = UUID()
        let appName: String
        let bundleIdentifier: String
        let containerPath: String
        let exists: Bool
        let wechatFilesPath: String
        let wechatFilesExists: Bool
        let activeWxid: String?
        let wxidCount: Int
        let expectedWxid: String?
        let bindingStatus: String
        /// 目录在但读不进去：macOS 会保护其他应用的容器数据，需要完全磁盘访问授权
        let unreadable: Bool
    }

    struct CloneCleanupResult {
        let kept: Int
        let deletedPaths: [String]
        let skippedRunning: Int
    }

    private struct TrashedItem {
        let originalPath: String
        let trashedPath: String
    }

    private enum UndoOperation {
        case restoreMappings(aliases: [String: String], expectedWxids: [String: String])
        case restoreTrashedItems(items: [TrashedItem], summary: String)
    }

    private let cloneRootDirectory: String = {
        let path = "\(NSHomeDirectory())/Applications/WeCloneClones"
        try? FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        return path
    }()
    private let defaultPreferredSecondCloneIndex = 2
    private let aliasStoreKey = "weclone.instance.aliases"
    private let expectedWxidStoreKey = "weclone.instance.expected_wxid"
    private let firstRunDoneKey = "weclone.first_run_done"
    @Published private(set) var launchLogs: [LaunchLogEntry] = []
    @Published private(set) var lastOperationMessage: String = ""
    @Published private(set) var canUndoLastAction: Bool = false
    /// 运行中实例摘要，由轮询在后台扫描后于主线程发布，界面与菜单栏共用
    @Published private(set) var runningSummaries: [RunningInstanceSummary] = []
    private var pendingUndoOperation: UndoOperation?
    private var summaryPollingTimer: Timer?
    /// 串号提醒开关（系统通知），持久化到 UserDefaults
    @Published var mismatchAlertEnabled: Bool {
        didSet {
            UserDefaults.standard.set(mismatchAlertEnabled, forKey: mismatchAlertEnabledKey)
        }
    }
    private let mismatchAlertEnabledKey = "weclone.mismatch_alert_enabled"
    /// 上一轮处于「账号对不上」状态的实例，只在状态变化时提醒，避免重复轰炸
    private var lastMismatchBundleIds: Set<String> = []

    init() {
        if UserDefaults.standard.object(forKey: mismatchAlertEnabledKey) == nil {
            mismatchAlertEnabled = true
        } else {
            mismatchAlertEnabled = UserDefaults.standard.bool(forKey: mismatchAlertEnabledKey)
        }
        ensureAliasDefaults()
    }

    /// 获取当前运行的微信数量
    func getRunningWeChatCount() -> Int {
        NSWorkspace.shared.runningApplications.filter(isMainWeChatApp).count
    }

    /// 启动一个新的微信实例
    func launchNewWeChat() -> Bool {
        guard let sourceURL = findWeChatApp() else {
            appendLaunchLog(
                bundleIdentifier: "com.tencent.xinWeChat",
                appPath: "/Applications/WeChat.app",
                status: "失败",
                detail: "未找到微信应用"
            )
            return false
        }

        let currentCount = getRunningWeChatCount()
        if currentCount == 0 {
            return launchApp(at: sourceURL.path, bundleIdentifier: "com.tencent.xinWeChat")
        }

        let cloneIndex = nextCloneIndexForLaunch()
        guard let clonedPath = ensureClonedWeChat(sourcePath: sourceURL.path, cloneIndex: cloneIndex) else {
            return false
        }
        return launchApp(at: clonedPath, bundleIdentifier: "com.tencent.xinWeChat.multi\(cloneIndex)")
    }

    /// 启动指定路径的应用
    private func launchApp(at path: String, bundleIdentifier: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            appendLaunchLog(
                bundleIdentifier: bundleIdentifier,
                appPath: path,
                status: "失败",
                detail: "应用路径不存在"
            )
            return false
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", "-a", path]
        do {
            try task.run()
            appendLaunchLog(
                bundleIdentifier: bundleIdentifier,
                appPath: path,
                status: "已发起",
                detail: "已请求启动实例"
            )
            return true
        } catch {
            appendLaunchLog(
                bundleIdentifier: bundleIdentifier,
                appPath: path,
                status: "失败",
                detail: "启动命令失败: \(error.localizedDescription)"
            )
            return false
        }
    }

    /// 关闭所有微信实例
    func closeAllWeChat() {
        let weChatApps = NSWorkspace.shared.runningApplications.filter(isMainWeChatApp)

        for app in weChatApps {
            app.terminate()
        }
    }

    /// 只关闭指定实例的微信主进程
    func closeWeChatInstance(bundleId: String) {
        NSWorkspace.shared.runningApplications
            .filter { isMainWeChatApp($0) && $0.bundleIdentifier == bundleId }
            .forEach { $0.terminate() }
    }

    /// 重启单个实例：运行中先退出，进程结束后再按原样开回来
    func relaunchInstance(bundleId: String) -> String {
        let name = getInstanceDisplayName(for: bundleId)
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            isMainWeChatApp($0) && $0.bundleIdentifier == bundleId
        }
        for app in runningApps {
            app.terminate()
        }
        if !runningApps.isEmpty {
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline,
                  NSWorkspace.shared.runningApplications.contains(where: {
                      isMainWeChatApp($0) && $0.bundleIdentifier == bundleId
                  }) {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        if launchInstance(for: bundleId) {
            return "\(name)：已发起重启。"
        }
        return "\(name)：重启失败，没有找到可启动的副本。"
    }

    /// 删除一个副本窗口：副本应用与数据容器一起进废纸篓，并清掉名称与账号记忆
    func deleteInstance(bundleId: String) -> String {
        guard bundleId != "com.tencent.xinWeChat" else {
            return "微信主程序不能在这里删除。"
        }
        if getRunningMainWeChatBundleIds().contains(bundleId) {
            return "这个微信窗口还在运行，先退出再删除。"
        }

        let name = getInstanceDisplayName(for: bundleId)
        var trashedItems: [TrashedItem] = []
        if let index = cloneIndex(fromBundleId: bundleId) {
            let clonePath = "\(cloneRootDirectory)/WeChat\(index).app"
            if let trashed = moveToTrash(path: clonePath) {
                trashedItems.append(trashed)
            }
        }
        let containerPath = "\(NSHomeDirectory())/Library/Containers/\(bundleId)"
        if let trashed = moveToTrash(path: containerPath) {
            trashedItems.append(trashed)
        }

        var aliases = loadAliases()
        aliases.removeValue(forKey: bundleId)
        saveAliases(aliases)
        var expected = loadExpectedWxids()
        expected.removeValue(forKey: bundleId)
        saveExpectedWxids(expected)

        guard !trashedItems.isEmpty else {
            return "没有找到这个窗口的副本内容，可能已经删过了。"
        }
        setUndoOperation(.restoreTrashedItems(items: trashedItems, summary: "已删除窗口（可撤销）"))
        return "已删除 \(name)：副本与数据目录进了废纸篓，可在维护页撤销。"
    }

    /// 副本是否落后于原版微信（下次启动这个副本时会自动重建）
    func cloneNeedsSync(bundleId: String) -> Bool {
        guard bundleId != "com.tencent.xinWeChat",
              let index = cloneIndex(fromBundleId: bundleId),
              let source = findWeChatApp() else {
            return false
        }
        let clonePath = "\(cloneRootDirectory)/WeChat\(index).app"
        guard FileManager.default.fileExists(atPath: clonePath) else {
            return false
        }
        return needsUpdate(clonePath: clonePath, sourcePath: source.path)
    }

    /// 递归统计目录的磁盘占用（字节）。目录不存在或不可读返回 nil。
    /// 只统计普通文件的实际占块大小，符号链接不展开；耗时与文件数成正比，调用方须放在后台线程。
    func directorySize(_ path: String) -> Int64? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path),
              let enumerator = fileManager.enumerator(atPath: path) else {
            return nil
        }
        var total: Int64 = 0
        let baseURL = URL(fileURLWithPath: path)
        while let relative = enumerator.nextObject() as? String {
            let url = baseURL.appendingPathComponent(relative)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// 启动指定数量的微信（总数）
    func launchWeChatUpTo(_ targetCount: Int) {
        let currentCount = getRunningWeChatCount()
        let needed = max(0, targetCount - currentCount)

        for _ in 0..<needed {
            _ = launchNewWeChat()
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    /// 确保指定序号的微信克隆存在，若原版更新则自动同步
    private func ensureClonedWeChat(sourcePath: String, cloneIndex: Int) -> String? {
        let clonedPath = "\(cloneRootDirectory)/WeChat\(cloneIndex).app"
        let bundleId = "com.tencent.xinWeChat.multi\(cloneIndex)"

        if FileManager.default.fileExists(atPath: clonedPath) {
            // 副本身份不对（改名失败或来历不明的手工拷贝）会顶替原版身份、混入窗口列表，直接重建
            let existingBundleId = readBundleIdentifier(fromAppPath: clonedPath)
            if existingBundleId != bundleId {
                do {
                    try FileManager.default.removeItem(atPath: clonedPath)
                } catch {
                    appendLaunchLog(
                        bundleIdentifier: bundleId,
                        appPath: clonedPath,
                        status: "失败",
                        detail: "副本身份不对（标成了 \(existingBundleId ?? "未知")）且无法删除，请手动处理 \(clonedPath)"
                    )
                    return nil
                }
                appendLaunchLog(
                    bundleIdentifier: bundleId,
                    appPath: clonedPath,
                    status: "重建中",
                    detail: "副本身份不对（标成了 \(existingBundleId ?? "未知")），正在重建"
                )
            } else if needsUpdate(clonePath: clonedPath, sourcePath: sourcePath) {
                do {
                    try FileManager.default.removeItem(atPath: clonedPath)
                    appendLaunchLog(
                        bundleIdentifier: bundleId,
                        appPath: clonedPath,
                        status: "同步中",
                        detail: "检测到原版微信已更新，正在重建克隆"
                    )
                } catch {
                    appendLaunchLog(
                        bundleIdentifier: bundleId,
                        appPath: clonedPath,
                        status: "同步失败",
                        detail: "删除旧版克隆失败，将使用旧版启动: \(error.localizedDescription)"
                    )
                    return clonedPath
                }
            } else {
                return clonedPath
            }
        }

        guard copyBundleWithCloneSupport(from: sourcePath, to: clonedPath) else {
            appendLaunchLog(
                bundleIdentifier: bundleId,
                appPath: clonedPath,
                status: "失败",
                detail: "复制微信失败"
            )
            return nil
        }

        guard updateBundleMetadata(appPath: clonedPath, bundleId: bundleId, displayName: "WeChat\(cloneIndex)"),
              readBundleIdentifier(fromAppPath: clonedPath) == bundleId else {
            // 改名没写成会留下一个顶着原版身份的假副本，必须清掉
            try? FileManager.default.removeItem(atPath: clonedPath)
            appendLaunchLog(
                bundleIdentifier: bundleId,
                appPath: clonedPath,
                status: "失败",
                detail: "更新克隆应用元数据失败，已清理残留"
            )
            return nil
        }

        signApp(appPath: clonedPath)
        return clonedPath
    }

    /// 把未运行的旧副本重建为写时复制克隆，回收完整拷贝占用的空间。
    /// 副本只是入口，重建不影响任何账号数据；运行中的副本不动。
    func rebuildStoppedClones() -> String {
        let running = Set(getRunningMainWeChatBundleIds())
        let clones = listCloneApps()
        guard let source = findWeChatApp() else {
            return "未找到原版微信，无法重建。"
        }
        guard !clones.isEmpty else {
            return "没有可重建的副本。"
        }

        var rebuilt = 0
        var skippedRunning = 0
        var failed = 0
        for clone in clones {
            if running.contains(clone.bundleId) {
                skippedRunning += 1
                continue
            }
            guard let index = cloneIndex(fromBundleId: clone.bundleId) else {
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: clone.path)
            } catch {
                failed += 1
                continue
            }
            if ensureClonedWeChat(sourcePath: source.path, cloneIndex: index) != nil {
                rebuilt += 1
            } else {
                failed += 1
            }
        }

        if rebuilt == 0 && skippedRunning == 0 && failed == 0 {
            return "没有可重建的副本。"
        }
        var parts: [String] = ["已重建 \(rebuilt) 个副本"]
        if skippedRunning > 0 { parts.append("跳过运行中 \(skippedRunning) 个") }
        if failed > 0 { parts.append("失败 \(failed) 个") }
        return parts.joined(separator: "，") + "。"
    }

    /// 用 APFS 写时复制克隆应用包：整树瞬时完成，实际新增磁盘占用远小于完整拷贝。
    /// clonefile 失败（非 APFS 卷、跨卷等）时回退逐文件克隆，再回退普通拷贝。
    private func copyBundleWithCloneSupport(from sourcePath: String, to destPath: String) -> Bool {
        let source = sourcePath as NSString
        let dest = destPath as NSString
        if clonefile(source.fileSystemRepresentation, dest.fileSystemRepresentation, 0) == 0 {
            return true
        }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        if copyfile(sourcePath, destPath, state, flags) == 0 {
            return true
        }
        do {
            try FileManager.default.copyItem(atPath: sourcePath, toPath: destPath)
            return true
        } catch {
            return false
        }
    }

    /// 更新克隆应用的 bundle 信息，避免实例互斥
    private func updateBundleMetadata(appPath: String, bundleId: String, displayName: String) -> Bool {
        let plistPath = "\(appPath)/Contents/Info.plist"
        let task = Process()
        task.launchPath = "/usr/libexec/PlistBuddy"
        task.arguments = [
            "-c", "Set :CFBundleIdentifier \(bundleId)",
            "-c", "Set :CFBundleName \(displayName)",
            "-c", "Set :CFBundleDisplayName \(displayName)",
            plistPath
        ]
        task.launch()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// 对克隆应用做 ad-hoc 签名，保证可启动
    private func signApp(appPath: String) {
        let task = Process()
        task.launchPath = "/usr/bin/codesign"
        task.arguments = ["--force", "--deep", "--sign", "-", appPath]
        task.launch()
        task.waitUntilExit()
    }

    /// 获取每个微信实例的数据容器目录
    func getInstanceStoragePaths() -> [InstanceStoragePath] {
        var result: [InstanceStoragePath] = []
        let uniqueBundleIds = sortedBundleIds(Array(Set(listKnownBundleIdentifiers())))
        ensureAliasDefaults()
        for bundleId in uniqueBundleIds {
            let containerPath = "\(NSHomeDirectory())/Library/Containers/\(bundleId)"
            let wechatFilesPath = "\(containerPath)/Data/Documents/xwechat_files"
            let appName = getInstanceDisplayName(for: bundleId)
            let wxidInfo = detectWxidInfo(in: wechatFilesPath)
            let expectedWxid = getExpectedWxid(for: bundleId)
            result.append(
                InstanceStoragePath(
                    appName: appName,
                    bundleIdentifier: bundleId,
                    containerPath: containerPath,
                    exists: FileManager.default.fileExists(atPath: containerPath),
                    wechatFilesPath: wechatFilesPath,
                    wechatFilesExists: FileManager.default.fileExists(atPath: wechatFilesPath),
                    activeWxid: wxidInfo.activeWxid,
                    wxidCount: wxidInfo.wxidCount,
                    expectedWxid: expectedWxid,
                    bindingStatus: computeBindingStatus(activeWxid: wxidInfo.activeWxid, expectedWxid: expectedWxid),
                    unreadable: wxidInfo.unreadable
                )
            )
        }

        return result
    }

    /// 启动运行态轮询：磁盘扫描放后台线程，结果在主线程发布，避免阻塞界面
    func startSummaryPolling(interval: TimeInterval = 2.0) {
        summaryPollingTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshSummariesNow()
        }
        summaryPollingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshSummariesNow()
    }

    func refreshSummariesNow() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let summaries = self.getRunningInstanceSummaries()
            DispatchQueue.main.async {
                self.publishSummaries(summaries)
            }
        }
    }

    /// 主线程发布运行态，并对新出现的串号实例发系统提醒
    private func publishSummaries(_ summaries: [RunningInstanceSummary]) {
        var currentMismatch = Set<String>()
        for summary in summaries {
            guard let active = summary.activeWxid, !active.isEmpty,
                  let expected = summary.expectedWxid, !expected.isEmpty,
                  active != expected else { continue }
            currentMismatch.insert(summary.bundleIdentifier)
        }
        let freshMismatches = currentMismatch.subtracting(lastMismatchBundleIds)
        lastMismatchBundleIds = currentMismatch
        runningSummaries = summaries

        guard mismatchAlertEnabled, !freshMismatches.isEmpty else { return }
        for summary in summaries where freshMismatches.contains(summary.bundleIdentifier) {
            postMismatchNotification(for: summary)
        }
    }

    private func postMismatchNotification(for summary: RunningInstanceSummary) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self?.addMismatchNotification(for: summary)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        self?.addMismatchNotification(for: summary)
                    }
                }
            default:
                break
            }
        }
    }

    private func addMismatchNotification(for summary: RunningInstanceSummary) {
        let content = UNMutableNotificationContent()
        content.title = "WeClone 串号提醒"
        content.body = "「\(summary.displayName)」现在登录的是 \(shortWxid(summary.activeWxid))，记住的却是 \(shortWxid(summary.expectedWxid))，发消息前注意别串号。"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "weclone.mismatch.\(summary.bundleIdentifier)",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func shortWxid(_ wxid: String?) -> String {
        guard let wxid, !wxid.isEmpty else { return "（无）" }
        guard wxid.count > 12 else { return wxid }
        return "\(wxid.prefix(6))…\(wxid.suffix(4))"
    }

    func getRunningInstanceSummaries() -> [RunningInstanceSummary] {
        // 同一 bundleId 跑出多个进程时只算一个窗口，避免重复卡片
        let bundleIds = sortedBundleIds(Array(Set(getRunningMainWeChatBundleIds())))
        return bundleIds.map { bundleId in
            let wechatFilesPath = "\(NSHomeDirectory())/Library/Containers/\(bundleId)/Data/Documents/xwechat_files"
            let wxidInfo = detectWxidInfo(in: wechatFilesPath)
            let expectedWxid = getExpectedWxid(for: bundleId)
            return RunningInstanceSummary(
                bundleIdentifier: bundleId,
                displayName: getInstanceDisplayName(for: bundleId),
                activeWxid: wxidInfo.activeWxid,
                expectedWxid: expectedWxid,
                bindingStatus: computeBindingStatus(activeWxid: wxidInfo.activeWxid, expectedWxid: expectedWxid)
            )
        }
    }

    func setInstanceDisplayName(_ displayName: String, for bundleId: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        var aliases = loadAliases()
        if trimmed.isEmpty {
            aliases.removeValue(forKey: bundleId)
        } else {
            aliases[bundleId] = trimmed
        }
        saveAliases(aliases)
    }

    func bindExpectedWxid(_ wxid: String?, for bundleId: String) {
        let trimmed = (wxid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var store = loadExpectedWxids()
        if trimmed.isEmpty {
            store.removeValue(forKey: bundleId)
        } else {
            store[bundleId] = trimmed
        }
        saveExpectedWxids(store)
    }

    /// 按已绑定实例重启，避免运行态混乱（不自动改账号，仅重建实例入口顺序）
    func relaunchByBindings() -> String {
        let boundBundleIds = sortedBundleIds(Array(loadExpectedWxids().keys))
        guard !boundBundleIds.isEmpty else {
            return "未配置任何绑定，无法按绑定修正。"
        }

        closeAllWeChat()
        Thread.sleep(forTimeInterval: 1.0)

        var launched: [String] = []
        var failed: [String] = []
        for bundleId in boundBundleIds {
            if launchInstance(for: bundleId) {
                launched.append(getInstanceDisplayName(for: bundleId))
            } else {
                failed.append(getInstanceDisplayName(for: bundleId))
            }
            Thread.sleep(forTimeInterval: 0.6)
        }

        if failed.isEmpty {
            return "已按绑定重启：\(launched.joined(separator: "、"))"
        }
        return "部分重启失败，成功：\(launched.joined(separator: "、"))；失败：\(failed.joined(separator: "、"))"
    }

    /// 将当前运行实例按当前活跃 wxid 一键绑定（默认最多绑定前两个）
    func autoBindRunningInstances(limit: Int = 2) -> String {
        let normalizedLimit = max(1, limit)
        let running = getRunningInstanceSummaries()
            .filter { ($0.activeWxid ?? "").isEmpty == false }

        guard !running.isEmpty else {
            return "未识别到可绑定的运行实例。"
        }

        let selected = Array(running.prefix(normalizedLimit))
        for item in selected {
            bindExpectedWxid(item.activeWxid, for: item.bundleIdentifier)
        }

        let mappedNames = selected.map { "\($0.displayName)→\($0.activeWxid ?? "-")" }
        return "已绑定 \(selected.count) 个微信：\(mappedNames.joined(separator: "、"))"
    }

    func clearLaunchLogs() {
        launchLogs.removeAll()
    }

    /// 导出前重置本机映射（仅清理本机配置，不动微信数据）
    func resetLocalMappingsForExport() -> String {
        let aliasesSnapshot = loadAliases()
        let expectedSnapshot = loadExpectedWxids()

        UserDefaults.standard.removeObject(forKey: aliasStoreKey)
        UserDefaults.standard.removeObject(forKey: expectedWxidStoreKey)
        ensureAliasDefaults()
        setUndoOperation(.restoreMappings(aliases: aliasesSnapshot, expectedWxids: expectedSnapshot))
        lastOperationMessage = "已重置本机映射（别名与账号绑定）"
        return lastOperationMessage
    }

    /// 清理克隆应用，仅保留最近的 N 个
    func cleanupClones(keepRecentCount: Int) -> CloneCleanupResult {
        let keep = max(0, keepRecentCount)
        let clones = listCloneApps()
        let sorted = clones.sorted { lhs, rhs in
            lhs.modifiedAt > rhs.modifiedAt
        }
        let runningBundleIds = Set(getRunningMainWeChatBundleIds())

        let toDelete = sorted.dropFirst(keep)
        var deleted: [String] = []
        var skippedRunning = 0
        var trashedItems: [TrashedItem] = []

        for clone in toDelete {
            if runningBundleIds.contains(clone.bundleId) {
                skippedRunning += 1
                continue
            }

            if let trashed = moveToTrash(path: clone.path) {
                deleted.append(clone.path)
                trashedItems.append(trashed)
            } else {
                do {
                    try FileManager.default.removeItem(atPath: clone.path)
                    deleted.append(clone.path)
                } catch {
                    print("删除克隆失败: \(clone.path), error: \(error)")
                }
            }

            // 同步清理未运行实例的容器目录，避免残留 multiX 持续显示
            let containerPath = "\(NSHomeDirectory())/Library/Containers/\(clone.bundleId)"
            if FileManager.default.fileExists(atPath: containerPath) {
                if let trashedContainer = moveToTrash(path: containerPath) {
                    trashedItems.append(trashedContainer)
                } else {
                    do {
                        try FileManager.default.removeItem(atPath: containerPath)
                    } catch {
                        print("删除容器失败: \(containerPath), error: \(error)")
                    }
                }
            }
        }

        if !trashedItems.isEmpty {
            let summary = "已清理 \(deleted.count) 个克隆（可撤销）"
            setUndoOperation(.restoreTrashedItems(items: trashedItems, summary: summary))
        }

        return CloneCleanupResult(
            kept: min(keep, sorted.count),
            deletedPaths: deleted,
            skippedRunning: skippedRunning
        )
    }

    func undoLastOperation() -> String {
        guard let operation = pendingUndoOperation else {
            return "暂无可撤销操作。"
        }

        switch operation {
        case let .restoreMappings(aliases, expectedWxids):
            saveAliases(aliases)
            saveExpectedWxids(expectedWxids)
            clearUndoOperation()
            lastOperationMessage = "已撤销：恢复本机映射。"
            return lastOperationMessage
        case let .restoreTrashedItems(items, summary):
            var restored = 0
            for item in items {
                if restoreFromTrash(trashedPath: item.trashedPath, originalPath: item.originalPath) {
                    restored += 1
                }
            }
            clearUndoOperation()
            lastOperationMessage = "已撤销：恢复 \(restored)/\(items.count) 个项目（原操作：\(summary)）。"
            return lastOperationMessage
        }
    }

    func copyDiagnosticsToPasteboard() -> String {
        let report = buildDiagnosticsReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        return "诊断信息已复制，可直接粘贴发我或发给其他人排查。"
    }

    func resolveFirstRunState() -> FirstRunState {
        let isFirstRun = !UserDefaults.standard.bool(forKey: firstRunDoneKey)
        let duplicatePaths = detectOtherRunningHelperPaths()
        if isFirstRun {
            UserDefaults.standard.set(true, forKey: firstRunDoneKey)
        }
        return FirstRunState(isFirstRun: isFirstRun, duplicateAppPaths: duplicatePaths)
    }

    private func listCloneAppPaths() -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: cloneRootDirectory) else {
            return []
        }
        return items
            .filter { $0.hasPrefix("WeChat") && $0.hasSuffix(".app") }
            .map { "\(cloneRootDirectory)/\($0)" }
    }

    private struct CloneAppInfo {
        let path: String
        let bundleId: String
        let modifiedAt: Date
    }

    private func listCloneApps() -> [CloneAppInfo] {
        listCloneAppPaths().compactMap { path in
            guard let bundleId = readBundleIdentifier(fromAppPath: path) else {
                return nil
            }
            return CloneAppInfo(
                path: path,
                bundleId: bundleId,
                modifiedAt: modificationDate(ofPath: path)
            )
        }
    }

    private func readBundleIdentifier(fromAppPath appPath: String) -> String? {
        let plistPath = "\(appPath)/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = raw as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }

    private func needsUpdate(clonePath: String, sourcePath: String) -> Bool {
        guard let source = readAppVersion(at: sourcePath),
              let clone = readAppVersion(at: clonePath) else {
            return false
        }
        return source.compare(clone, options: .numeric) == .orderedDescending
    }

    private func readAppVersion(at appPath: String) -> String? {
        let plistPath = "\(appPath)/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = raw as? [String: Any] else {
            return nil
        }
        return plist["CFBundleShortVersionString"] as? String
    }

    private func modificationDate(ofPath path: String) -> Date {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date else {
            return .distantPast
        }
        return date
    }

    private func listKnownBundleIdentifiers() -> [String] {
        var bundleIds: [String] = ["com.tencent.xinWeChat"]

        for clonePath in listCloneAppPaths() {
            // 只认身份正常的副本；改名失败的坏副本不作为窗口展示
            if let bundleId = readBundleIdentifier(fromAppPath: clonePath),
               bundleId == "com.tencent.xinWeChat" || cloneIndex(fromBundleId: bundleId) != nil {
                bundleIds.append(bundleId)
            }
        }

        for app in NSWorkspace.shared.runningApplications {
            // 只认主程序和副本；WeChatAppEx 等子进程的 id 也带同款前缀，混进来会多出假窗口
            if let bundleId = app.bundleIdentifier,
               bundleId == "com.tencent.xinWeChat" || cloneIndex(fromBundleId: bundleId) != nil {
                bundleIds.append(bundleId)
            }
        }

        return bundleIds
    }

    private func getInstanceDisplayName(for bundleId: String) -> String {
        let aliases = loadAliases()
        if let alias = aliases[bundleId]?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            return alias
        }
        if bundleId == "com.tencent.xinWeChat" {
            return "微信"
        }
        if let index = cloneIndex(fromBundleId: bundleId) {
            return "微信\(index)"
        }
        return bundleId
    }

    private func ensureAliasDefaults() {
        var aliases = loadAliases()
        if (aliases["com.tencent.xinWeChat"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aliases["com.tencent.xinWeChat"] = "微信"
        }

        saveAliases(aliases)
    }

    private func loadAliases() -> [String: String] {
        guard let dict = UserDefaults.standard.dictionary(forKey: aliasStoreKey) as? [String: String] else {
            return [:]
        }
        return dict
    }

    private func saveAliases(_ aliases: [String: String]) {
        UserDefaults.standard.set(aliases, forKey: aliasStoreKey)
    }

    private func loadExpectedWxids() -> [String: String] {
        guard let dict = UserDefaults.standard.dictionary(forKey: expectedWxidStoreKey) as? [String: String] else {
            return [:]
        }
        return dict
    }

    private func saveExpectedWxids(_ values: [String: String]) {
        UserDefaults.standard.set(values, forKey: expectedWxidStoreKey)
    }

    private func setUndoOperation(_ operation: UndoOperation) {
        pendingUndoOperation = operation
        canUndoLastAction = true
    }

    private func clearUndoOperation() {
        pendingUndoOperation = nil
        canUndoLastAction = false
    }

    private func getExpectedWxid(for bundleId: String) -> String? {
        let store = loadExpectedWxids()
        let value = store[bundleId]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
            return value
        }
        return nil
    }

    private func launchInstance(for bundleId: String) -> Bool {
        if bundleId == "com.tencent.xinWeChat" {
            guard let sourceURL = findWeChatApp() else {
                appendLaunchLog(
                    bundleIdentifier: bundleId,
                    appPath: "/Applications/WeChat.app",
                    status: "失败",
                    detail: "未找到原版微信"
                )
                return false
            }
            return launchApp(at: sourceURL.path, bundleIdentifier: bundleId)
        }

        guard let cloneIndex = cloneIndex(fromBundleId: bundleId),
              let sourceURL = findWeChatApp(),
              let clonePath = ensureClonedWeChat(sourcePath: sourceURL.path, cloneIndex: cloneIndex) else {
            appendLaunchLog(
                bundleIdentifier: bundleId,
                appPath: "\(cloneRootDirectory)/unknown.app",
                status: "失败",
                detail: "无法准备克隆实例"
            )
            return false
        }
        return launchApp(at: clonePath, bundleIdentifier: bundleId)
    }

    private func computeBindingStatus(activeWxid: String?, expectedWxid: String?) -> String {
        if let expectedWxid, !expectedWxid.isEmpty {
            guard let activeWxid, !activeWxid.isEmpty else {
                return "未识别到当前账号（期望 \(expectedWxid)）"
            }
            if activeWxid == expectedWxid {
                return "账号和绑定一致"
            }
            return "账号和绑定不一致：当前 \(activeWxid) / 绑定 \(expectedWxid)"
        }
        if let activeWxid, !activeWxid.isEmpty {
            return "未绑定（当前账号 \(activeWxid)）"
        }
        return "未绑定且未识别账号"
    }

    private func sortedBundleIds(_ bundleIds: [String]) -> [String] {
        bundleIds.sorted { lhs, rhs in
            if lhs == "com.tencent.xinWeChat" { return true }
            if rhs == "com.tencent.xinWeChat" { return false }
            let lIndex = cloneIndex(fromBundleId: lhs) ?? Int.max
            let rIndex = cloneIndex(fromBundleId: rhs) ?? Int.max
            if lIndex == rIndex {
                return lhs < rhs
            }
            return lIndex < rIndex
        }
    }

    private func moveToTrash(path: String) -> TrashedItem? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let sourceURL = URL(fileURLWithPath: path)
        var trashedURL: NSURL?
        do {
            try FileManager.default.trashItem(at: sourceURL, resultingItemURL: &trashedURL)
            if let trashed = trashedURL as URL? {
                return TrashedItem(originalPath: path, trashedPath: trashed.path)
            }
        } catch {
            print("移到废纸篓失败: \(path), error: \(error)")
        }
        return nil
    }

    private func restoreFromTrash(trashedPath: String, originalPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: trashedPath) else {
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: originalPath) {
                try FileManager.default.removeItem(atPath: originalPath)
            }
            try FileManager.default.moveItem(atPath: trashedPath, toPath: originalPath)
            return true
        } catch {
            print("从废纸篓恢复失败: \(trashedPath) -> \(originalPath), error: \(error)")
            return false
        }
    }

    private func detectOtherRunningHelperPaths() -> [String] {
        let currentExecutable = Bundle.main.executableURL?.path ?? ""
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    return false
                }
                guard let exec = app.executableURL?.path else {
                    return false
                }
                guard exec.hasSuffix("/WeClone") else {
                    return false
                }
                return exec != currentExecutable
            }
            .compactMap { $0.bundleURL?.path }
            .sorted()
    }

    private func buildDiagnosticsReport() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let appPath = Bundle.main.bundleURL.path
        let count = getRunningWeChatCount()
        let summaries = getRunningInstanceSummaries()
        let paths = getInstanceStoragePaths()
        let lines: [String] = [
            "WeClone Diagnostics",
            "time=\(ISO8601DateFormatter().string(from: Date()))",
            "app=\(appPath)",
            "version=\(version) (\(build))",
            "running_count=\(count)",
            "running=\(summaries.map { "\($0.displayName):\($0.activeWxid ?? "-")|\($0.bindingStatus)" }.joined(separator: " ; "))",
            "paths=\(paths.map { "\($0.appName):\($0.wechatFilesPath)" }.joined(separator: " ; "))",
            "last_operation=\(lastOperationMessage)"
        ]
        return lines.joined(separator: "\n")
    }

    private func detectWxidInfo(in wechatFilesPath: String) -> (activeWxid: String?, wxidCount: Int, unreadable: Bool) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            atPath: wechatFilesPath
        ) else {
            // 目录在但读不进去（别的应用的容器数据受系统保护），和「目录不存在」要区分开
            if FileManager.default.fileExists(atPath: wechatFilesPath) {
                return (nil, 0, true)
            }
            return (nil, 0, false)
        }

        let wxids = items.filter { $0.hasPrefix("wxid_") }
        guard !wxids.isEmpty else {
            return (nil, 0, false)
        }

        var latestWxid: String?
        var latestDate: Date = .distantPast
        for wxid in wxids {
            let date = accountActivityDate(at: "\(wechatFilesPath)/\(wxid)")
            if date > latestDate {
                latestDate = date
                latestWxid = wxid
            }
        }

        return (latestWxid, wxids.count, false)
    }

    /// 账号最近活跃时间。微信登录后的写入大多发生在 db_storage/config 深层文件，
    /// 账号目录自身的 mtime 基本不动，只看它会把活跃账号判旧；
    /// 对这两个轻量目录做有上限的抽样，取最新文件时间。
    private func accountActivityDate(at accountPath: String) -> Date {
        var latest = modificationDate(ofPath: accountPath)
        let fileManager = FileManager.default
        for section in ["db_storage", "config"] {
            let sectionPath = "\(accountPath)/\(section)"
            guard let entries = try? fileManager.contentsOfDirectory(atPath: sectionPath) else {
                continue
            }
            for entry in entries.prefix(40) {
                let entryPath = "\(sectionPath)/\(entry)"
                var isDir: ObjCBool = false
                fileManager.fileExists(atPath: entryPath, isDirectory: &isDir)
                if isDir.boolValue {
                    guard let files = try? fileManager.contentsOfDirectory(atPath: entryPath) else {
                        continue
                    }
                    for file in files.prefix(40) {
                        let date = modificationDate(ofPath: "\(entryPath)/\(file)")
                        if date > latest {
                            latest = date
                        }
                    }
                } else {
                    let date = modificationDate(ofPath: entryPath)
                    if date > latest {
                        latest = date
                    }
                }
            }
        }
        return latest
    }

    private func appendLaunchLog(
        bundleIdentifier: String,
        appPath: String,
        status: String,
        detail: String
    ) {
        let entry = LaunchLogEntry(
            timestamp: Date(),
            displayName: getInstanceDisplayName(for: bundleIdentifier),
            bundleIdentifier: bundleIdentifier,
            appPath: appPath,
            status: status,
            detail: detail
        )
        launchLogs.insert(entry, at: 0)
        if launchLogs.count > 60 {
            launchLogs = Array(launchLogs.prefix(60))
        }
        lastOperationMessage = "\(entry.displayName)：\(status)（\(detail)）"
    }

    private func getRunningMainWeChatBundleIds() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter(isMainWeChatApp)
            .compactMap { $0.bundleIdentifier }
    }

    /// 第二个微信固定使用 multi2，保证双开目录长期稳定
    private func nextCloneIndexForLaunch() -> Int {
        let runningBundleIds = Set(getRunningMainWeChatBundleIds())
        let preferredIndex = preferredSecondCloneIndex()
        let preferredBundleId = "com.tencent.xinWeChat.multi\(preferredIndex)"
        if !runningBundleIds.contains(preferredBundleId) {
            return preferredIndex
        }

        var index = preferredIndex + 1
        while runningBundleIds.contains("com.tencent.xinWeChat.multi\(index)") {
            index += 1
        }
        return index
    }

    /// 优先沿用已有实例编号，避免用户反复重新登录不同目录
    private func preferredSecondCloneIndex() -> Int {
        let runningMultiIndexes = getRunningMainWeChatBundleIds()
            .compactMap { cloneIndex(fromBundleId: $0) }
        if let runningFirst = runningMultiIndexes.sorted().first {
            return runningFirst
        }

        let existingMultiIndexes = listCloneApps()
            .compactMap { cloneIndex(fromBundleId: $0.bundleId) }
        if let existingFirst = existingMultiIndexes.sorted().first {
            return existingFirst
        }

        return defaultPreferredSecondCloneIndex
    }

    private func cloneIndex(fromBundleId bundleId: String) -> Int? {
        let prefix = "com.tencent.xinWeChat.multi"
        guard bundleId.hasPrefix(prefix) else {
            return nil
        }
        return Int(bundleId.replacingOccurrences(of: prefix, with: ""))
    }

    /// 仅识别微信主进程，排除 WeChatAppEx/Helper 等子进程
    private func isMainWeChatApp(_ app: NSRunningApplication) -> Bool {
        guard let execName = app.executableURL?.lastPathComponent, execName == "WeChat" else {
            return false
        }
        guard let bundleId = app.bundleIdentifier, bundleId.hasPrefix("com.tencent.xinWeChat") else {
            return false
        }
        return true
    }

    /// 查找微信应用路径
    private func findWeChatApp() -> URL? {
        let paths = [
            "/Applications/WeChat.app",
            "/Applications/微信.app"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
