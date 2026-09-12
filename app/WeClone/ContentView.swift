import SwiftUI

struct ContentView: View {
    @ObservedObject var weChatManager: WeChatManager
    var onOpenDashboard: () -> Void
    @State private var targetCount: String = "2"
    @Environment(\.dismiss) private var dismiss

    var currentCount: Int {
        weChatManager.getRunningWeChatCount()
    }

    var runningNames: String {
        let names = weChatManager.getRunningInstanceSummaries().map { $0.displayName }
        return names.isEmpty ? "无" : names.joined(separator: "、")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BrandLogoView(size: 24)
                Text("微信多开助手")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(currentCount > 0 ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(currentCount > 0 ? "运行中 \(currentCount) 个：\(runningNames)" : "暂无微信运行")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Divider()

            Button(action: {
                _ = weChatManager.launchNewWeChat()
                dismiss()
            }) {
                Label("再开一个微信", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 8) {
                Text("同时开")
                    .font(.system(size: 12))
                TextField("2", text: $targetCount)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .multilineTextAlignment(.center)
                Text("个微信")
                    .font(.system(size: 12))
                Spacer()
                Button("开始") {
                    if let count = Int(targetCount), count > 0 {
                        weChatManager.launchWeChatUpTo(count)
                        dismiss()
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("管理面板") {
                    onOpenDashboard()
                    dismiss()
                }
                Button("全部关闭") {
                    weChatManager.closeAllWeChat()
                    dismiss()
                }
                .tint(.red)
                Spacer()
                Button("退出") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(width: 310)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
    }
}
