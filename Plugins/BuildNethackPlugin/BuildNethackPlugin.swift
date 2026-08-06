import PackagePlugin
import Foundation

@main
struct BuildNethackPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        // TODO: Implement once the NetHack build configuration is known.
        //
        // Expected steps:
        //   1. Run the NetHack configure step (if needed) in context.package.directory / "vendor/NetHack"
        //   2. Run 'make <target>' there to produce libnethack.a
        //   3. Copy libnethack.a  → vendor/lib/libnethack.a
        //   4. Copy public headers → vendor/include/
        //   5. Write vendor/lib/pkgconfig/nethack.pc with absolute paths
        //
        // Then build normally with:
        //   PKG_CONFIG_PATH=vendor/lib/pkgconfig swift build
        throw PluginError.notImplemented
    }
}

enum PluginError: Error, CustomStringConvertible {
    case notImplemented

    var description: String {
        switch self {
        case .notImplemented:
            return "BuildNethack: not yet implemented — build libnethack manually for now."
        }
    }
}
