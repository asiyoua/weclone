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

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    var dmgAsset: Asset? {
        assets.first { $0.name.hasSuffix(".dmg") }
    }
}

enum AutoUpdateError: LocalizedError {
    case badResponse
    case sizeMismatch
    case noInstallerAsset

    var errorDescription: String? {
        switch self {
        case .badResponse: return "更新服务器响应异常"
        case .sizeMismatch: return "下载的更新包大小不符"
        case .noInstallerAsset: return "更新中缺少安装包"
        }
    }
}

// MARK: - Auto update controller

/// 检查 GitHub Releases，发现新版本时弹窗询问（立即更新/暂不更新），
/// 同意后自动下载，并由独立 helper 等本进程退出后替换 /Applications/WeClone.app
/// 再重启。新旧包 bundle id 一致，账号绑定与所有设置在更新后原样保留。
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
    /// 自动检查更新开关，持久化到 UserDefaults；切换即重新调度监控
    @Published var autoUpdateEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoUpdateEnabled, forKey: autoUpdateEnabledKey)
            if oldValue != autoUpdateEnabled {
                startMonitoring()
            }
        }
    }

    private let autoUpdateEnabledKey = "weclone.auto_update_enabled"

    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let downloadSizeCap = 64 * 1024 * 1024

    private var timer: Timer?
    private var scheduledCheck: Task<Void, Never>?
    private var pendingRelease: WeCloneReleaseInfo?
    private var skippedVersion: String?

    init() {
        if UserDefaults.standard.object(forKey: autoUpdateEnabledKey) == nil {
            autoUpdateEnabled = true
        } else {
            autoUpdateEnabled = UserDefaults.standard.bool(forKey: autoUpdateEnabledKey)
        }
    }

    var isChecking: Bool {
        if case .checking = phase { return true }
        return false
    }

    func startMonitoring() {
        timer?.invalidate()
        timer = nil
        guard autoUpdateEnabled else {
            phase = .idle
            return
        }
        scheduleCheck(after: 10)
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkAndInstallIfNeeded() }
        }
    }

    func checkNow() {
        scheduleCheck(after: 0)
    }

    private func scheduleCheck(after seconds: TimeInterval) {
        scheduledCheck?.cancel()
        scheduledCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.checkAndInstallIfNeeded()
        }
    }

    func checkAndInstallIfNeeded() async {
        guard autoUpdateEnabled else {
            phase = .idle
            return
        }
        phase = .checking
        do {
            let release = try await fetchLatestRelease()
            let local = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard UpdateChecker.compare(local: local, remoteTag: release.tagName) == .remoteNewer else {
                phase = .upToDate
                return
            }
            guard release.dmgAsset != nil else {
                throw AutoUpdateError.noInstallerAsset
            }
            // 本会话内用户已对同一版本点过「暂不」，静默视为最新，不再打扰
            guard release.tagName != skippedVersion else {
                phase = .upToDate
                return
            }
            pendingRelease = release
            phase = .available(version: release.tagName)
            presentUpdatePrompt(version: release.tagName)
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

    /// 非阻塞提示窗：普通 NSWindow + SwiftUI，不跑 modal 或 sheet
    private func presentUpdatePrompt(version: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
            styleMask: [.titled],
            backing: .buffered, defer: false)
        window.title = "WeClone 更新"
        window.contentView = NSHostingView(
            rootView: UpdatePromptView(
                version: version,
                onConfirm: { [weak self] in
                    self?.closePromptWindow()
                    self?.confirmUpdate()
                },
                onPostpone: { [weak self] in
                    self?.closePromptWindow()
                    self?.postponeUpdate()
                }))
        window.center()
        promptWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePromptWindow() {
        promptWindow?.orderOut(nil)
        promptWindow = nil
    }

    func confirmUpdate() {
        guard let release = pendingRelease, case .available = phase else { return }
        guard let dmg = release.dmgAsset, let url = URL(string: dmg.browserDownloadURL) else {
            phase = .failed(AutoUpdateError.noInstallerAsset.localizedDescription)
            return
        }
        Task { [weak self] in
            await self?.downloadAndInstall(release: release, assetURL: url, expectedSize: dmg.size)
        }
    }

    func postponeUpdate() {
        if let release = pendingRelease {
            skippedVersion = release.tagName
        }
        pendingRelease = nil
        phase = .upToDate
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
        var request = URLRequest(url: UpdateChecker.latestReleaseURL)
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AutoUpdateError.badResponse
        }
        return try JSONDecoder().decode(WeCloneReleaseInfo.self, from: data)
    }

    private func fetchReleaseViaPageRedirect() async throws -> WeCloneReleaseInfo {
        var request = URLRequest(url: UpdateChecker.latestReleasePageURL)
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let tag = UpdateChecker.tagFromFinalURL(response.url)
        else {
            throw AutoUpdateError.badResponse
        }
        let version = UpdateChecker.stripLeadingV(tag)
        let asset = WeCloneReleaseInfo.Asset(
            name: "WeClone-\(version).dmg", size: 0,
            browserDownloadURL: "https://github.com/asiyoua/weclone/releases/download/\(tag)/WeClone-\(version).dmg")
        return WeCloneReleaseInfo(tagName: tag, assets: [asset])
    }

    private func download(
        from url: URL, expectedSize: Int, progress: @escaping (Double) -> Void
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
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
    private func applyStagedUpdateAndRelaunch(dmgFile: URL) {
        let mountPoint = "/tmp/weclone-update-mount"
        let script = """
        set -e
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
            pgrep -f "WeClone.app/Contents/MacOS/WeClone" >/dev/null 2>&1 || break
            sleep 0.5
        done
        mkdir -p "\(mountPoint)"
        hdiutil attach "\(dmgFile.path)" -nobrowse -readonly -mountpoint "\(mountPoint)" >/dev/null
        rm -rf /Applications/WeClone.app
        cp -R "\(mountPoint)/WeClone.app" /Applications/
        hdiutil detach "\(mountPoint)" >/dev/null 2>&1 || true
        rm -f "\(dmgFile.path)"
        rmdir "\(mountPoint)" 2>/dev/null || true
        open /Applications/WeClone.app
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

private struct UpdatePromptView: View {
    let version: String
    let onConfirm: () -> Void
    let onPostpone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("发现新版本 \(version)，要现在更新吗？")
                .font(.system(size: 13, weight: .semibold))
            Text("将自动下载并替换 /Applications 里的 WeClone，账号绑定和设置都会保留。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("暂不更新") { onPostpone() }
                    .keyboardShortcut(.cancelAction)
                Button("立即更新") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
