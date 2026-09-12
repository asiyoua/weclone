import SwiftUI

struct OnboardingView: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            BrandLogoView(size: 72)

            VStack(spacing: 4) {
                Text("欢迎使用 WeClone")
                    .font(.system(size: 24, weight: .bold))
                Text("轻松实现微信多开，稳定不串号")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 18) {
                stepRow(number: 1, title: "再开一个微信", desc: "点击按钮，自动创建第二个微信窗口")
                stepRow(number: 2, title: "扫码登录", desc: "用另一个手机微信扫码登录第二个账号")
                stepRow(number: 3, title: "记住账号", desc: "绑定后下次启动自动对应，不会串号")
            }
            .padding(.horizontal, 16)

            Spacer()

            Button("开始使用") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(width: 200)
        }
        .padding(32)
        .frame(width: 440, height: 500)
    }

    private func stepRow(number: Int, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }
}
