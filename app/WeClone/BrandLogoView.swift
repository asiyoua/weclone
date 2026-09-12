import SwiftUI

struct BrandLogoView: View {
    var size: CGFloat = 36

    var body: some View {
        if let nsImage = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.blue, Color.cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    Text("W")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundColor(.white)
                )
        }
    }
}
