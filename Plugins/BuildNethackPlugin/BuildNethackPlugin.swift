import PackagePlugin
import Foundation

@main
struct BuildNethackPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let packageDir = context.package.directoryURL.path(percentEncoded: false)
        let nethackDir = "\(packageDir)/vendor/NetHack"
        let isDebug = arguments.contains("--debug")

        if isDebug {
            print("Building in debug mode (-g -O0)")
        }

        // 1. Run setup.sh to generate the top-level Makefile and platform config.
        print("Step 1/3: Configuring (setup.sh)...")
        try runProcess("/bin/sh",
                       arguments: ["setup.sh", "hints/macOS.500"],
                       workingDirectory: "\(nethackDir)/sys/unix")

        // 2. Download and unpack the embedded Lua library.
        print("Step 2/3: Fetching Lua...")
        try runProcess("/usr/bin/make",
                       arguments: ["fetch-lua"],
                       workingDirectory: nethackDir)

        // 3. Build libnh.a.
        print("Step 3/3: Building libnh.a...")
        var makeArgs = ["WANT_LIBNH=1"]
        if isDebug {
            makeArgs.append("CFLAGS=-g -O0")
        }
        makeArgs.append("all")
        try runProcess("/usr/bin/make",
                       arguments: makeArgs,
                       workingDirectory: nethackDir)

        print("""

            Build complete. libnh.a is at vendor/NetHack/src/libnh.a

            Add libnh.a to your app target's "Link Binary With Libraries" build
            phase and add vendor/NetHack/src to its library search paths.
            """)
    }

    private func runProcess(_ executable: String,
                             arguments: [String],
                             workingDirectory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PluginError.commandFailed(
                URL(fileURLWithPath: executable).lastPathComponent,
                Int(process.terminationStatus))
        }
    }
}

enum PluginError: Error, CustomStringConvertible {
    case commandFailed(String, Int)

    var description: String {
        switch self {
        case .commandFailed(let cmd, let code):
            return "\(cmd) exited with status \(code)"
        }
    }
}
