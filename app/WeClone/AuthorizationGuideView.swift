import SwiftUI
import Cocoa

/// 「完全磁盘访问权限」重新授权引导。微信更新或 WeClone 更新后，
/// 旧的授权记录会失效，只在列表里开开关没用：
/// 必须先把旧的一行删掉、重新添加应用、再打开开关。
struct AuthorizationGuideView: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("需要重新授权")
                    .font(.system(size: 20, weight: .bold))
                Text("微信更新后，WeClone 读取账号数据的许可失效了")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                stepRow(1, text: "点下面按钮，打开「完全磁盘访问权限」")
                stepRow(2, text: "在列表里选中 WeClone，点 − 把这一行删掉")
                stepRow(3, text: "点 ＋，在「应用程序」里选 WeClone 重新加进来")
                stepRow(4, text: "把开关打开，回到这里点「完成」")
            }

            Spacer()

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button("打开系统设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(30)
        .frame(width: 480, height: 400)
    }

    private func stepRow(_ number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
