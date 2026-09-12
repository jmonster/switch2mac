import Foundation

/// Supported physical Nintendo controller models, identified by Nintendo product ID.
/// A Joy-Con is one physical controller; logical pairing belongs to the host.
public enum Switch2ControllerModel: UInt16, CaseIterable, Codable, Sendable {
    /// Right Joy-Con 2 (one right stick and optical sensor).
    case joyCon2Right = 0x2066
    /// Left Joy-Con 2 (one left stick and optical sensor).
    case joyCon2Left = 0x2067
    /// Nintendo Switch 2 Pro Controller (two sticks and two rumble actuators).
    case proController2 = 0x2069
    /// Nintendo Switch Online GameCube controller (analog trigger travel).
    case nsoGameCube = 0x2073

    /// Model name, independent of a host application's custom controller name.
    public var displayName: String {
        switch self {
        case .joyCon2Right: return "Joy-Con 2 (R)"
        case .joyCon2Left: return "Joy-Con 2 (L)"
        case .proController2: return "Pro Controller 2"
        case .nsoGameCube: return "NSO GameCube Controller"
        }
    }
    /// Whether trigger travel is analog rather than derived from ZL/ZR buttons.
    public var hasAnalogTriggers: Bool { self == .nsoGameCube }
    /// Whether the physical controller has both a left and a right stick.
    public var hasSecondStick: Bool { self == .proController2 || self == .nsoGameCube }
    /// Whether the established Pro/Joy-Con rumble protocol is supported.
    /// GameCube preset diagnostics are deliberately not included.
    public var hasHDRumble: Bool { self != .nsoGameCube }
    /// Model-level capabilities. A connected snapshot may remove unavailable features.
    public var capabilities: Switch2ControllerCapabilities {
        var result: Switch2ControllerCapabilities = [.buttons, .battery, .motion, .magnetometer, .playerLEDs]
        if self != .joyCon2Right { result.insert(.leftStick) }
        if self != .joyCon2Left { result.insert(.rightStick) }
        if hasAnalogTriggers { result.insert(.analogTriggers) }
        if hasHDRumble { result.insert(.rumble) }
        if self == .joyCon2Left || self == .joyCon2Right { result.insert(.opticalSensor) }
        return result
    }
}

/// Features exposed by a controller snapshot. These do not imply system-wide game support.
public struct Switch2ControllerCapabilities: OptionSet, Hashable, Codable, Sendable {
    /// Stable bit field. Unknown future bits must be ignored by consumers.
    public let rawValue: UInt32
    /// Creates a feature set from its bit field.
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    /// Buttons, including D-pad and digital shoulder/trigger bits.
    public static let buttons = Self(rawValue: 1 << 0)
    /// A calibrated or nominally normalized left stick.
    public static let leftStick = Self(rawValue: 1 << 1)
    /// A calibrated or nominally normalized right stick.
    public static let rightStick = Self(rawValue: 1 << 2)
    /// Independent 0...255 trigger travel, not a digital approximation.
    public static let analogTriggers = Self(rawValue: 1 << 3)
    /// Battery voltage and raw charging telemetry.
    public static let battery = Self(rawValue: 1 << 4)
    /// Raw gyroscope and accelerometer samples; not calibrated physical units.
    public static let motion = Self(rawValue: 1 << 5)
    /// Raw magnetic-field samples and the established 0.15 microtesla/count scale.
    public static let magnetometer = Self(rawValue: 1 << 6)
    /// Joy-Con optical counters and raw surface/lift readings.
    public static let opticalSensor = Self(rawValue: 1 << 7)
    /// Established Pro/Joy-Con rumble operations on the negotiated link.
    public static let rumble = Self(rawValue: 1 << 8)
    /// Control of the four player indicator LEDs.
    public static let playerLEDs = Self(rawValue: 1 << 9)
}

/// Controller button bits. Digital trigger/click bits remain independent of analog travel.
/// The D-pad uses four independent bits; opposing directions are not synthesized away.
public struct Switch2Buttons: OptionSet, Hashable, Codable, Sendable, CaseIterable {
    /// The controller's decoded 32-bit button mask; unknown bits are preserved.
    public let rawValue: UInt32
    /// Creates a button mask, for example when restoring a mapping or writing a test.
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    /// Y button, when present on the physical model.
    public static let y = Self(rawValue: 0x0000_0001)
    /// X button, when present on the physical model.
    public static let x = Self(rawValue: 0x0000_0002)
    /// B button, when present on the physical model.
    public static let b = Self(rawValue: 0x0000_0004)
    /// A button, when present on the physical model.
    public static let a = Self(rawValue: 0x0000_0008)
    /// SR (right unit) button, when present on the physical model.
    public static let srR = Self(rawValue: 0x0000_0010)
    /// SL (right unit) button, when present on the physical model.
    public static let slR = Self(rawValue: 0x0000_0020)
    /// R button, when present on the physical model.
    public static let r = Self(rawValue: 0x0000_0040)
    /// ZR button, when present on the physical model.
    public static let zr = Self(rawValue: 0x0000_0080)
    /// Minus button, when present on the physical model.
    public static let minus = Self(rawValue: 0x0000_0100)
    /// Plus button, when present on the physical model.
    public static let plus = Self(rawValue: 0x0000_0200)
    /// R-stick click button, when present on the physical model.
    public static let rStick = Self(rawValue: 0x0000_0400)
    /// L-stick click button, when present on the physical model.
    public static let lStick = Self(rawValue: 0x0000_0800)
    /// Home button, when present on the physical model.
    public static let home = Self(rawValue: 0x0000_1000)
    /// Capture button, when present on the physical model.
    public static let capture = Self(rawValue: 0x0000_2000)
    /// C button, when present on the physical model.
    public static let c = Self(rawValue: 0x0000_4000)
    /// D-pad Down button, when present on the physical model.
    public static let dpadDown = Self(rawValue: 0x0001_0000)
    /// D-pad Up button, when present on the physical model.
    public static let dpadUp = Self(rawValue: 0x0002_0000)
    /// D-pad Right button, when present on the physical model.
    public static let dpadRight = Self(rawValue: 0x0004_0000)
    /// D-pad Left button, when present on the physical model.
    public static let dpadLeft = Self(rawValue: 0x0008_0000)
    /// SR (left unit) button, when present on the physical model.
    public static let srL = Self(rawValue: 0x0010_0000)
    /// SL (left unit) button, when present on the physical model.
    public static let slL = Self(rawValue: 0x0020_0000)
    /// L button, when present on the physical model.
    public static let l = Self(rawValue: 0x0040_0000)
    /// ZL button, when present on the physical model.
    public static let zl = Self(rawValue: 0x0080_0000)
    /// GR button, when present on the physical model.
    public static let gr = Self(rawValue: 0x0100_0000)
    /// GL button, when present on the physical model.
    public static let gl = Self(rawValue: 0x0200_0000)
    /// Every individually named control, in dashboard-compatible presentation order.
    public static let allCases: [Self] = [.a, .b, .x, .y, .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .l, .r, .zl, .zr, .minus, .plus, .home, .capture, .c, .lStick, .rStick, .gl, .gr, .slL, .srL, .slR, .srR]
    /// A display label for a single known control; combined or unknown masks use hexadecimal.
    public var displayName: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .dpadUp: return "D-pad Up"
        case .dpadDown: return "D-pad Down"
        case .dpadLeft: return "D-pad Left"
        case .dpadRight: return "D-pad Right"
        case .l: return "L"
        case .r: return "R"
        case .zl: return "ZL"
        case .zr: return "ZR"
        case .minus: return "Minus"
        case .plus: return "Plus"
        case .home: return "Home"
        case .capture: return "Capture"
        case .c: return "C"
        case .lStick: return "L-stick click"
        case .rStick: return "R-stick click"
        case .gl: return "GL"
        case .gr: return "GR"
        case .slL: return "SL (left unit)"
        case .srL: return "SR (left unit)"
        case .slR: return "SL (right unit)"
        case .srR: return "SR (right unit)"
        default: return String(format: "0x%08x", rawValue)
        }
    }
}
