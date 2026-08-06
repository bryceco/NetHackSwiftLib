// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SwiftLibNethack",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "SwiftLibNethack",
            targets: ["SwiftLibNethack"]
        ),
    ],
    targets: [
        // Wraps the pre-built libnethack.a via pkg-config.
        // Run 'swift package build-nethack' first to build the library and generate
        // vendor/lib/pkgconfig/nethack.pc, then build with:
        //   PKG_CONFIG_PATH=vendor/lib/pkgconfig swift build
        .systemLibrary(
            name: "CLibNethack",
            path: "Sources/CLibNethack",
            pkgConfig: "nethack"
        ),

        // Swift API layer on top of CLibNethack.
        .target(
            name: "SwiftLibNethack",
            dependencies: ["CLibNethack"]
        ),

        // Command plugin: 'swift package build-nethack'
        // Builds libnethack from source in vendor/NetHack/ using make.
        .plugin(
            name: "BuildNethackPlugin",
            capability: .command(
                intent: .custom(
                    verb: "build-nethack",
                    description: "Build libnethack from source using make"
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Writes libnethack.a, public headers, and nethack.pc to vendor/lib/ and vendor/include/"
                    ),
                ]
            )
        ),
    ],
    swiftLanguageModes: [.v6]
)
