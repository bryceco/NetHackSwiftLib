// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "NetHackSwiftLib",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "NetHackSwiftLib",
            targets: ["NetHackBridge"]
        ),
    ],
    targets: [
        // Objective-C bridge: owns the C callback and all libnh interop.
        // NetHackBridge.m forward-declares the libnh symbols it uses, so
        // this target compiles without linking libnh.a. The consuming app is
        // responsible for adding libnh.a to its link step.
        .target(
            name: "NetHackBridge",
            path: "Sources/NetHackBridge",
            publicHeadersPath: "include",
        ),
    ],
    swiftLanguageModes: [.v6]
)
