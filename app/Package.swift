// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WeClone",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "WeClone", targets: ["WeClone"])
    ],
    targets: [
        .executableTarget(
            name: "WeClone",
            path: "WeClone",
            resources: [
                .process("Assets.xcassets")
            ]
        )
    ]
)
