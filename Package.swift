// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ATLAS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
        .executable(name: "AtlasApp", targets: ["AtlasApp"]),
        // Ships inside Atlas.app so it signs with the same identity.
        .executable(name: "atlasctl", targets: ["AtlasCtl"])
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/Luminare.git", from: "0.2.0"),
        // Prebuilt SQLCipher xcframework. Direct-mode transcripts are encrypted
        // at rest; the passphrase lives in the Keychain.
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", from: "4.18.0")
    ],
    targets: [
        .target(
            name: "AtlasCore",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")],
            path: "Sources/AtlasCore",
            // Vendor/ is build input for scripts/build_field.sh, not shipped —
            // its contents are already inside Resources/field.bundle.js.
            exclude: ["Vendor"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "AtlasApp",
            dependencies: [
                "AtlasCore",
                .product(name: "Luminare", package: "Luminare")
            ],
            path: "Sources/AtlasApp"
        ),
        .executableTarget(
            name: "AtlasCtl",
            dependencies: ["AtlasCore"],
            path: "Sources/AtlasCtl"
        ),
        .testTarget(
            name: "AtlasCoreTests",
            dependencies: ["AtlasCore"],
            path: "Tests/AtlasCoreTests"
        )
    ]
)
