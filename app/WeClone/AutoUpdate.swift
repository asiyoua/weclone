import AppKit
import SwiftUI

// MARK: - GitHub release metadata

struct WeCloneReleaseInfo: Decodable {
    struct Asset: Decodable {
        let name: String
        let size: Int
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let assets: [Asset]
    /// Release 说明正文（GitHub API 才有；限流回退路径拿不到）
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
        case body
    }

    var dmgAsset: Asset? {
        assets.first { $0.name.hasSuffix(".dmg") }
    }
}

/// 更新弹窗说明框里的一行：标题行加粗，普通行带圆点
struct ReleaseNoteLine: Equatable {
    let isHeader: Bool
    let text: String
}

enum AutoUpdateError: LocalizedError {
    case badResponse
    case sizeMismatch
    case noInstallerAsset
    case untrustedUpdateHost

    var errorDescription: String? {
        switch self {
        case .badResponse: return "更新服务器响应异常"
        case .sizeMismatch: return "下载的更新包大小不符"
        case .noInstallerAsset: return "更新中缺少安装包"
        case .untrustedUpdateHost: return "更新源地址不受信任"
        }
    }
}

// MARK: - Trusted host guard

extension UpdateChecker {
    /// 更新请求只允许 GitHub 官方域名（https），防止 release 元数据被
    /// 篡改后把安装包指到任意主机。
    static func isTrustedUpdateHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "api.github.com" || host == "github.com"
            || host == "objects.githubusercontent.com" || host == "release-assets.githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }

    static func safeUpdateURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", isTrustedUpdateHost(url.host) else {
            return nil
        }
        return url
    }
}

/// 更新专用 URLSession：重定向目标同样过域名白名单，不合规就拒绝跟随。
final class UpdateRedirectGuard: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let session: URLSession = {
        let guardDelegate = UpdateRedirectGuard()
        return URLSession(configuration: .default, delegate: guardDelegate, delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme == "https", UpdateChecker.isTrustedUpdateHost(request.url?.host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

// MARK: - Auto update controller

/// 自动（每日）检查 GitHub Releases，发现新版本弹更新窗：发布说明、跳过此版本、
/// 稍后提醒、自动安装；「关于」页「检查更新」是手动入口，不受任何跳过记录影响。
/// 点「安装更新」后同一窗口原地直接下载安装包并显示进度，失败就地显示原因并可
/// 重试；下载完成后由独立 helper 等本进程退出后替换已安装的 WeClone 并重启。
@MainActor
final class AutoUpdateController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading(progress: Double)
        case installing
        case failed(String)
    }

    @Published var phase: Phase = .idle
    /// 自动检查更新开关（弹窗提醒），持久化到 UserDefaults；切换即重新调度监控
    @Published var autoUpdateEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoUpdateEnabled, forKey: autoUpdateEnabledKey)
            if oldValue != autoUpdateEnabled {
                startMonitoring()
            }
        }
    }
    /// 「自动安装更新」勾选：发现新版本后不询问，直接下载并安装
    @Published var autoInstallUpdates: Bool {
        didSet {
            UserDefaults.standard.set(autoInstallUpdates, forKey: autoInstallUpdatesKey)
        }
    }
    /// 更新弹窗「跳过此版本」记下的 tag；自动检查跳过它，手动检查不受限
    @Published var updateSkippedTag: String? {
        didSet {
            UserDefaults.standard.set(updateSkippedTag ?? "", forKey: updateSkippedTagKey)
        }
    }

    private let autoUpdateEnabledKey = "weclone.auto_update_enabled"
    private let autoInstallUpdatesKey = "weclone.auto_install_updates"
    private let updateSkippedTagKey = "weclone.update_skipped_tag"

    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let downloadSizeCap = 64 * 1024 * 1024
    static let promptWindowSize = NSSize(width: 460, height: 392)

    private var timer: Timer?
    private var scheduledCheck: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var pendingRelease: WeCloneReleaseInfo?
    private var skippedVersion: String?

    init() {
        if UserDefaults.standard.object(forKey: autoUpdateEnabledKey) == nil {
            autoUpdateEnabled = true
        } else {
            autoUpdateEnabled = UserDefaults.standard.bool(forKey: autoUpdateEnabledKey)
        }
        autoInstallUpdates = UserDefaults.standard.object(forKey: autoInstallUpdatesKey) as? Bool ?? false
        if let skipped = UserDefaults.standard.string(forKey: updateSkippedTagKey), !skipped.isEmpty {
            updateSkippedTag = skipped
        }
    }

    var isChecking: Bool {
        if case .checking = phase { return true }
        return false
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        case .idle, .upToDate, .available, .failed: return false
        }
    }

    /// 是否有可展示的检查状态（idle 时「关于」页状态行不显示）
    var hasStatus: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// 本机当前版本号
    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 待更新版本的说明行（无正文时为空数组）
    var releaseNoteLines: [ReleaseNoteLine] {
        guard let body = pendingRelease?.body,
            !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        return Self.parseReleaseNotes(body)
    }

    /// 把 Release 正文（轻量 markdown）拆成弹窗说明框的行
    nonisolated static func parseReleaseNotes(_ body: String) -> [ReleaseNoteLine] {
        body.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            var isHeader = false
            while line.hasPrefix("#") {
                isHeader = true
                line = String(line.dropFirst())
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if !isHeader {
                for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                    line = String(line.dropFirst(marker.count))
                    break
                }
                // 「- 」这类空列表项被行尾 trim 后只剩符号本身
                if line == "-" || line == "*" || line == "•" { return nil }
            }
            line = line
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            guard !line.isEmpty else { return nil }
            return ReleaseNoteLine(isHeader: isHeader, text: line)
        }
    }

    func startMonitoring() {
        timer?.invalidate()
        timer = nil
        guard autoUpdateEnabled else {
            phase = .idle
            return
        }
        scheduleCheck(after: 10, manual: false)
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.runCheck(manual: false) }
        }
    }

    /// 「关于」页「检查更新」：手动触发，不受自动更新开关和跳过记录影响
    func checkManually() {
        guard !isBusy else { return }
        scheduleCheck(after: 0, manual: true)
    }

    private func scheduleCheck(after seconds: TimeInterval, manual: Bool) {
        scheduledCheck?.cancel()
        scheduledCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.runCheck(manual: manual)
        }
    }

    func runCheck(manual: Bool) async {
        if !manual {
            guard autoUpdateEnabled else {
                phase = .idle
                return
            }
        }
        phase = .checking
        do {
            let release = try await fetchLatestRelease()
            let local = currentVersion
            guard UpdateChecker.compare(local: local, remoteTag: release.tagName) == .remoteNewer else {
                phase = .upToDate
                return
            }
            guard release.dmgAsset != nil else {
                throw AutoUpdateError.noInstallerAsset
            }
            // 自动检查时，本会话点过「稍后提醒」、或用户曾点「跳过此版本」
            // 的 tag 都不再打扰；手动检查是用户点名要看，两条都无视
            if !manual, release.tagName == skippedVersion || release.tagName == updateSkippedTag {
                phase = .upToDate
                return
            }
            pendingRelease = release
            phase = .available(version: release.tagName)
            presentUpdatePrompt(version: release.tagName)
            if autoInstallUpdates {
                startInstall()
            }
        } catch is CancellationError {
            // a newer check superseded this one
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    var statusText: String {
        switch phase {
        case .idle:
            return "—"
        case .checking:
            return "检查中……"
        case .upToDate:
            return "已是最新版本"
        case .available(let version):
            return "发现新版本 \(version)"
        case .downloading(let progress):
            return "下载中 \(Int(progress * 100))%"
        case .installing:
            return "正在安装……"
        case .failed(let message):
            return "检查失败：\(message)"
        }
    }

    // MARK: Update prompt

    private var promptWindow: NSWindow?
    private var promptWindowDelegate: UpdatePromptWindowDelegate?

    /// 非阻塞提示窗：普通 NSWindow + SwiftUI（不跑 modal 或 sheet），视图直接
    /// 观察 controller，点「安装更新」后同一窗口原地变成下载进度，失败就地显示
    /// 原因。窗口绝不 makeKey、按钮不挂快捷键：用户正在打字时误按回车不能
    /// 隔空触发安装（Pico v1.0.4 血泪教训）。
    private func presentUpdatePrompt(version: String) {
        if let window = promptWindow {
            positionPromptWindow(window)
            window.orderFrontRegardless()
            return
        }
        let size = Self.promptWindowSize
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WeClone 更新"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentViewController = NSHostingController(
            rootView: UpdatePromptView(controller: self))
        let delegate = UpdatePromptWindowDelegate { [weak self] in
            self?.remindLater()
        }
        promptWindowDelegate = delegate
        window.delegate = delegate
        promptWindow = window
        positionPromptWindow(window)
        window.orderFrontRegardless()
    }

    /// macOS 26 的 window.center() 会把窗放到屏幕外且缩水，必须显式
    /// setFrameOrigin
    private func positionPromptWindow(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let frame = window.frame
        let x = screen.visibleFrame.midX - frame.width / 2
        let y = screen.visibleFrame.midY - frame.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func closePromptWindow() {
        promptWindow?.orderOut(nil)
        promptWindow = nil
    }

    /// 「跳过此版本」：记进偏好，之后自动检查不再弹这个版本
    func skipThisVersion() {
        if let release = pendingRelease {
            updateSkippedTag = release.tagName
        }
        dismissPrompt()
    }

    /// 「稍后提醒我」/ 点关闭按钮：只在本会话内不再打扰同一版本
    func remindLater() {
        if let release = pendingRelease {
            skippedVersion = release.tagName
        }
        dismissPrompt()
    }

    private func dismissPrompt() {
        pendingRelease = nil
        closePromptWindow()
        phase = .upToDate
    }

    func confirmUpdate() {
        startInstall()
    }

    func retryInstall() {
        startInstall()
    }

    private func startInstall() {
        guard let release = pendingRelease else {
            phase = .failed(AutoUpdateError.noInstallerAsset.localizedDescription)
            return
        }
        guard let dmg = release.dmgAsset else {
            phase = .failed(AutoUpdateError.noInstallerAsset.localizedDescription)
            return
        }
        guard let url = UpdateChecker.safeUpdateURL(dmg.browserDownloadURL) else {
            phase = .failed(AutoUpdateError.untrustedUpdateHost.localizedDescription)
            return
        }
        installTask?.cancel()
        installTask = Task { [weak self] in
            await self?.downloadAndInstall(release: release, assetURL: url, expectedSize: dmg.size)
        }
    }

    private func downloadAndInstall(release: WeCloneReleaseInfo, assetURL: URL, expectedSize: Int) async {
        do {
            phase = .downloading(progress: 0)
            let data = try await download(from: assetURL, expectedSize: expectedSize) { [weak self] fraction in
                self?.phase = .downloading(progress: fraction)
            }
            phase = .installing
            let staged = try stageDownloadedUpdate(data: data, version: release.tagName)
            applyStagedUpdateAndRelaunch(dmgFile: staged)
            // helper 会等进程退出再换装；这里给 spawn 留半拍后优雅退出
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Steps

    private func fetchLatestRelease() async throws -> WeCloneReleaseInfo {
        do {
            return try await fetchReleaseViaAPI()
        } catch {
            // API 匿名限流按出口 IP 共享（挂代理时经常 403），回退到
            // releases/latest 页面重定向拿 tag；下载走附件直链，均无 API 限流
            return try await fetchReleaseViaPageRedirect()
        }
    }

    private func fetchReleaseViaAPI() async throws -> WeCloneReleaseInfo {
        guard let url = UpdateChecker.safeUpdateURL(UpdateChecker.latestReleaseURL.absoluteString) else {
            throw AutoUpdateError.untrustedUpdateHost
        }
        var request = URLRequest(url: url)
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await UpdateRedirectGuard.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AutoUpdateError.badResponse
        }
        return try JSONDecoder().decode(WeCloneReleaseInfo.self, from: data)
    }

    private func fetchReleaseViaPageRedirect() async throws -> WeCloneReleaseInfo {
        guard let url = UpdateChecker.safeUpdateURL(UpdateChecker.latestReleasePageURL.absoluteString) else {
            throw AutoUpdateError.untrustedUpdateHost
        }
        var request = URLRequest(url: url)
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await UpdateRedirectGuard.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let tag = UpdateChecker.tagFromFinalURL(response.url)
        else {
            throw AutoUpdateError.badResponse
        }
        let version = UpdateChecker.stripLeadingV(tag)
        let asset = WeCloneReleaseInfo.Asset(
            name: "WeClone-\(version).dmg", size: 0,
            browserDownloadURL: "https://github.com/asiyoua/weclone/releases/download/\(tag)/WeClone-\(version).dmg")
        return WeCloneReleaseInfo(tagName: tag, assets: [asset], body: nil)
    }

    private func download(
        from url: URL, expectedSize: Int, progress: @escaping (Double) -> Void
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        let (asyncBytes, response) = try await UpdateRedirectGuard.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AutoUpdateError.badResponse
        }
        var data = Data()
        data.reserveCapacity(expectedSize > 0 ? expectedSize : 0)
        var lastReport = Date.distantPast
        for try await byte in asyncBytes {
            data.append(byte)
            // 重定向回退拿不到 asset 元数据（size=0），用绝对上限兜底
            guard data.count <= Self.downloadSizeCap else {
                throw AutoUpdateError.sizeMismatch
            }
            if Date().timeIntervalSince(lastReport) > 0.2 {
                lastReport = Date()
                let fraction = expectedSize > 0 ? Double(data.count) / Double(expectedSize) : 0
                progress(min(max(fraction, 0), 1))
            }
        }
        guard expectedSize <= 0 || data.count == expectedSize else {
            throw AutoUpdateError.sizeMismatch
        }
        return data
    }

    private func stageDownloadedUpdate(data: Data, version: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weclone-update", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("WeClone-\(version).dmg")
        try data.write(to: file, options: .atomic)
        return file
    }

    /// Spawns a detached helper that waits for this app to exit, swaps the
    /// installed bundle with the staged DMG contents and relaunches. The
    /// helper survives the app quitting because it is orphaned to launchd.
    /// 按应用当前真实位置换装（不强制 /Applications）；App Translocation
    /// 下原地不可写，回落到 /Applications。
    private func applyStagedUpdateAndRelaunch(dmgFile: URL) {
        let mountPoint = "/tmp/weclone-update-mount"
        let bundlePath = Bundle.main.bundlePath
        let target = bundlePath.contains("AppTranslocation") ? "/Applications/WeClone.app" : bundlePath
        let parent = (target as NSString).deletingLastPathComponent
        let script = """
        set -e
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
            pgrep -f "WeClone.app/Contents/MacOS/WeClone" >/dev/null 2>&1 || break
            sleep 0.5
        done
        mkdir -p "\(mountPoint)"
        hdiutil attach "\(dmgFile.path)" -nobrowse -readonly -mountpoint "\(mountPoint)" >/dev/null
        rm -rf "\(target)"
        cp -R "\(mountPoint)/WeClone.app" "\(parent)/"
        hdiutil detach "\(mountPoint)" >/dev/null 2>&1 || true
        rm -f "\(dmgFile.path)"
        rmdir "\(mountPoint)" 2>/dev/null || true
        open "\(target)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// 点红色关闭钮等同「稍后提醒我」
final class UpdatePromptWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [onClose] in onClose() }
    }
}

/// 更新弹窗：图标 + 「WeClone x.y.z 可更新」+ 当前版本 + 可滚动的发布说明框
/// + 「自动安装」勾选 + 跳过/稍后/安装三键。窗口尺寸固定，见
/// AutoUpdateController.promptWindowSize。
private struct UpdatePromptView: View {
    @ObservedObject var controller: AutoUpdateController
    @State private var autoInstall: Bool

    init(controller: AutoUpdateController) {
        self.controller = controller
        _autoInstall = State(initialValue: controller.autoInstallUpdates)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch controller.phase {
            case .available:
                availableContent
            case .downloading(let progress):
                downloadingContent(progress: progress)
            case .installing:
                installingContent
            case .failed(let message):
                failedContent(message: message)
            case .checking:
                checkingContent
            case .idle, .upToDate:
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(
            width: AutoUpdateController.promptWindowSize.width,
            height: AutoUpdateController.promptWindowSize.height,
            alignment: .topLeading
        )
    }

    // MARK: 有新版本

    private var availableContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    if case .available(let version) = controller.phase {
                        Text("WeClone \(UpdateChecker.stripLeadingV(version)) 可更新")
                            .font(.system(size: 17, weight: .semibold))
                        Text("你当前使用的是 \(controller.currentVersion)")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
            }
            notesBox
            Toggle(isOn: Binding(
                get: { autoInstall },
                set: { autoInstall = $0; controller.autoInstallUpdates = $0 }
            )) {
                Text("自动下载并安装以后的更新")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 10) {
                Button("跳过此版本") { controller.skipThisVersion() }
                    .buttonStyle(.link)
                    .font(.callout)
                Spacer()
                Button("稍后提醒我") { controller.remindLater() }
                    .buttonStyle(.bordered)
                Button("安装更新") { controller.confirmUpdate() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var notesBox: some View {
        ScrollView {
            let lines = controller.releaseNoteLines
            VStack(alignment: .leading, spacing: 8) {
                if lines.isEmpty {
                    Text("这个版本没有写更新说明。")
                        .font(.callout)
                        .foregroundColor(.secondary.opacity(0.7))
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        if line.isHeader {
                            Text(line.text)
                                .font(.system(size: 13, weight: .semibold))
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("•")
                                    .foregroundColor(.secondary)
                                Text(line.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 190)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: 下载 / 安装 / 失败 / 检查中

    private func downloadingContent(progress: Double) -> some View {
        centeredMessage {
            VStack(spacing: 12) {
                Text(progress > 0 ? "下载中 \(Int(progress * 100))%" : "下载中……")
                    .font(.callout)
                    .foregroundColor(.secondary)
                if progress > 0 {
                    ProgressView(value: progress)
                        .frame(maxWidth: 300)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("下载完成后 WeClone 会自动重启完成安装。")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }

    private var installingContent: some View {
        centeredMessage {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在安装……")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func failedContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("更新失败：\(message)")
                .font(.callout)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("跳过此版本") { controller.skipThisVersion() }
                    .buttonStyle(.link)
                    .font(.callout)
                Spacer()
                Button("稍后提醒我") { controller.remindLater() }
                    .buttonStyle(.bordered)
                Button("重试") { controller.retryInstall() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 0)
        }
    }

    private var checkingContent: some View {
        centeredMessage {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("检查中……")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func centeredMessage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
