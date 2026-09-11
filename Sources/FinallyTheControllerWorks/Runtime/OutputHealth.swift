import Foundation

/// Facts about this process, not certification of input reaching a game.
enum OutputBackend: String, CaseIterable, Codable, Sendable {
    case sdl, browser, retroarch, hid
    var title: String {
        switch self {
        case .sdl: return "SDL bridge"
        case .browser: return "Chromium bridge"
        case .retroarch: return "RetroArch network output"
        case .hid: return "CoreHID virtual controller"
        }
    }
    var guideURL: URL {
        let path: String
        switch self {
        case .sdl: path = "sdl/README.md"
        case .browser: path = "browser/README.md"
        case .retroarch: path = "docs/retroarch-integration.md"
        case .hid: path = "docs/fork-identity.md"
        }
        return URL(string: "https://github.com/jmonster/switch2mac/blob/main/" + path)!
    }
}

struct OutputHealth: Equatable, Codable, Sendable {
    enum State: String, Codable, Sendable {
        case disabled, needsConfiguration, starting, listening, clientConnected
        case sendingUnconfirmed, idle, deviceActive, unavailable, degraded
    }
    let backend: OutputBackend
    let state: State
    var activeCount = 0
    var affectedSlots: [Int] = []

    var summary: String {
        switch state {
        case .disabled: return "Disabled"
        case .needsConfiguration: return "Configuration required"
        case .starting: return "Starting or retrying"
        case .listening: return "Listening; no recent client observed"
        case .clientConnected: return "Local client observed (\(activeCount))"
        case .sendingUnconfirmed: return "Configured; game receipt unconfirmed"
        case .idle: return "No active virtual controllers"
        case .deviceActive: return "Virtual devices active (\(activeCount))"
        case .unavailable: return "Unavailable"
        case .degraded: return "Partially available"
        }
    }
    var guidance: String {
        switch backend {
        case .sdl:
            return state == .unavailable || state == .degraded
                ? "Some loopback ports could not open. Quit other bridge instances, then refresh after the automatic retry."
                : "Use the rebuilt SDL library in the intended game. A recent UDP subscription is not proof the game consumed input."
        case .browser:
            return state == .unavailable || state == .starting
                ? "Check for another bridge using port 24810. The listener retries automatically. Open Browser Bridge Settings to check the exact extension ID."
                : "Enable the bridge, load the bundled Chromium extension and allow its exact ID. A native connection does not establish that a game tab consumed input."
        case .retroarch:
            return state == .degraded
                ? "Input delivery failed or exceeded its bounds. Disable and re-enable network output in Dashboard Configuration, then test in RetroArch."
                : "Match the enabled receiver and ports in RetroArch with Dashboard Configuration. This UDP protocol has no receipt acknowledgement or rumble return path."
        case .hid:
            return state == .unavailable || state == .degraded
                ? "Virtual-device creation or delivery failed. This may require Apple's restricted HID entitlement. Check the signing guide or choose another output; reconnect to retry."
                : "Generic HID compatibility depends on the game and signing entitlement. An activated device is not proof of game input; this output has no rumble return path."
        }
    }
}

protocol OutputHealthProviding: Sendable {
    var outputBackend: OutputBackend { get }
    func requestHealth(_ reply: @escaping @Sendable (OutputHealth) -> Void)
}

/// Model/backend policy is shared by the UI and its regression suite. Nothing
/// here enables sensors, sends motor commands, or expands protocol support.
struct OutputCapabilities: Sendable {
    let model: Switch2.Model
    let backend: OutputBackend
    var gameRumble: Bool { model.hasHDRumble && (backend == .sdl || backend == .browser) }
    var directRumble: Bool { model.hasHDRumble }
    var analogTravel: Bool { model.hasAnalogTriggers && backend != .retroarch }
    var motion: Bool { backend == .sdl }
    var explanation: String {
        let rumble = gameRumble ? "Game rumble has a return path; verify it in the actual game."
            : (model == .nsoGameCube ? "GameCube preset rumble is unverified; HD-motor commands are not sent."
               : "This output has no game-rumble return path. The Dashboard pulse tests the controller directly, not game rumble.")
        let triggers = model.hasAnalogTriggers
            ? (analogTravel ? "Analog trigger travel and digital clicks remain separate; test both in-game."
                            : "GameCube trigger travel is reduced to digital L2/R2 on this output.")
            : "ZL/ZR are digital controls on this model."
        let sensors = motion ? "SDL motion is opt-in and uses nominal conversion; per-model orientation needs qualification."
                             : "This output does not forward motion sensors."
        return [rumble, triggers, sensors, "NFC and headset audio are experiments, not supported gameplay features."].joined(separator: "\n\n")
    }
}
