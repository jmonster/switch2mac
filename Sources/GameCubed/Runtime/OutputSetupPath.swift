import Foundation

/// Instructions only: choosing a route never enables an output or a permission.
enum OutputSetupPath: String, CaseIterable, Identifiable {
    case sdl, retroarch, browser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sdl: return "SDL3 game or Gopher64"
        case .retroarch: return "RetroArch"
        case .browser: return "Chromium web game"
        }
    }

    var detail: String {
        switch self {
        case .sdl:
            return "Use the rebuilt, corrected SDL library for a compatible game. The tracked historical dylib does not include later fixes. Keep the original game unchanged."
        case .retroarch:
            return "Enable network gamepad input in RetroArch and output in the Dashboard with matching ports. No SDL replacement is needed. This path has no rumble or analog GameCube trigger travel; use a trusted network."
        case .browser:
            return "Load the bundled Chromium extension, allow its exact ID in Browser Bridge Settings, click Apply Changes, then reload the game tab. Safari and Firefox are not included."
        }
    }

    var guidePath: String {
        switch self {
        case .sdl: return "sdl/README.md"
        case .retroarch: return "docs/retroarch-integration.md"
        case .browser: return "browser/README.md"
        }
    }

    var guideURL: URL {
        Self.documentationURL(guidePath)
    }

    /// Bundled guides match the installed application and remain available offline.
    static func documentationURL(_ path: String) -> URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("Documentation", isDirectory: true)
            .appendingPathComponent(path)
    }

}
