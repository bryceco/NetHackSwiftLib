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
        // Objective-C bridge: owns the C callback and all libnh interop.
        // NetHackBridge.m forward-declares the two libnh symbols it uses, so
        // this target compiles without linking libnh.a. The consuming app is
        // responsible for adding libnh.a to its link step.
        .target(
            name: "NetHackBridge",
            path: "Sources/NetHackBridge",
            publicHeadersPath: "include"
        ),

        // Swift API layer.
        .target(
            name: "SwiftLibNethack",
            dependencies: ["NetHackBridge"]
        ),

        // Command plugin: 'swift package plugin build-nethack'
        // Builds libnh.a from source in vendor/NetHack/ using make.
        .plugin(
            name: "BuildNethackPlugin",
            capability: .command(
                intent: .custom(
                    verb: "build-nethack",
                    description: "Build libnh.a from source using make"
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Writes libnh.a to vendor/NetHack/src/"
                    ),
                ]
            )
        ),
    ],
    swiftLanguageModes: [.v6]
)
