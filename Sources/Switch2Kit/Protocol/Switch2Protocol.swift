// Switch2Protocol.swift
// The Nintendo Switch 2 controller BLE protocol: identifiers, GATT UUIDs,
// command framing, and input-report parsing.
//
// Protocol knowledge distilled from the community reverse-engineering effort
// (trevlars/switch2-controllers-linux, MIT; Nadeflore/switch2-controllers;
// the bitaxislabs BLE writeup), ported from our proven Python bridge.
//
// This file is transport-agnostic: no Bluetooth imports, fully unit-testable.

import Foundation

package enum Switch2 {

    // MARK: - Identification

    /// BLE advertising manufacturer-data company id used by Switch 2 pads.
    package static let nintendoCompanyID: UInt16 = 0x0553
    package static let nintendoVendorID: UInt16 = 0x057E

    package typealias Model = Switch2ControllerModel

    // MARK: - GATT characteristics

    package enum GATT {
        package static let inputReport = UUID(uuidString: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2")!
        package static let commandWrite = UUID(uuidString: "649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005")!
        package static let commandResponse = UUID(uuidString: "C765A961-D9D8-4D36-A20A-5315B111836A")!
        package static let vibrationPro = UUID(uuidString: "CC483F51-9258-427D-A939-630C31F72B05")!
        package static let vibrationJoyConR = UUID(uuidString: "FA19B0FB-CD1F-46A7-84A1-BBB09E00C149")!
        package static let vibrationJoyConL = UUID(uuidString: "289326CB-A471-485D-A8F4-240C14F18241")!

        package static func vibration(for model: Model) -> UUID {
            switch model {
            case .joyCon2Left: return vibrationJoyConL
            case .joyCon2Right: return vibrationJoyConR
            default: return vibrationPro  // Pro 2 and GameCube share it
            }
        }
    }

    // MARK: - Commands

    package enum Command {
        package static let memory: UInt8 = 0x02
        package static let leds: UInt8 = 0x09
        package static let vibration: UInt8 = 0x0A
        package static let feature: UInt8 = 0x0C
        package static let pair: UInt8 = 0x15
    }

    package enum Subcommand {
        package static let memoryRead: UInt8 = 0x04
        package static let ledsSetPlayer: UInt8 = 0x07
        package static let vibrationPlayPreset: UInt8 = 0x02
        package static let featureInit: UInt8 = 0x02
        package static let featureEnable: UInt8 = 0x04
        package static let pairSetMAC: UInt8 = 0x01
        package static let pairLTK1: UInt8 = 0x04
        package static let pairLTK2: UInt8 = 0x02
        package static let pairFinish: UInt8 = 0x03
    }

    /// Known finite GameCube clips, sent on the command characteristic with
    /// command 0x0A/subcommand 0x02, not on an HD-rumble characteristic.
    /// Wire format/preset IDs: trevlars/switch2-controllers-linux ngc/device.py
    /// (commit a0a36e6b88ed5500f60cac29815aabad0d8956bd). See docs/rumble.md.
    package enum GameCubeRumblePreset: UInt8 {
        case soft = 3
        case strong = 2

        package var payload: Data { Data([rawValue, 0, 0, 0]) }

        /// The 50% split is our test UI policy, not a continuous motor gain.
        /// Zero/non-finite intensity is silent; no undocumented stop preset.
        package static func forTest(intensity: Double) -> Self? {
            guard intensity.isFinite, intensity > 0 else { return nil }
            return intensity < 0.5 ? .soft : .strong
        }
    }

    package enum Feature {
        package static let motion: UInt8 = 0x04
        package static let mouse: UInt8 = 0x10       // optical sensor, Joy-Con 2 only
        package static let battery: UInt8 = 0x20     // battery current field
        package static let magnetometer: UInt8 = 0x80
        /// Base flags the console always sets alongside motion.
        package static let baseline: UInt8 = 0x03

        /// Explicit experimental consumer demand. Compatibility remains the
        /// default until real model/firmware acceptance and energy measurements
        /// justify reducing sensors automatically. Baseline and battery stay on.
        package enum SensorProfile: String, CaseIterable, Sendable {
            case compatibility, gamepad, motion, pointer
            package static func resolve(_ value: String?, acknowledged: Bool) -> Self {
                guard acknowledged, let value, let profile = Self(rawValue: value) else { return .compatibility }
                return profile
            }
        }
        package static let selectedProfile: SensorProfile = .compatibility

        /// Existing callers use one process-stable profile for BOTH feature
        /// initialization and enablement. No preferences are polled per report.
        package static func flags(for model: Model) -> UInt8 { flags(for: model, profile: selectedProfile) }

        package static func flags(for model: Model, profile: SensorProfile) -> UInt8 {
            let optical = model == .joyCon2Left || model == .joyCon2Right
            switch profile {
            case .compatibility:
                return baseline | motion | battery | magnetometer | (optical ? mouse : 0)
            case .gamepad:
                return baseline | battery
            case .motion:
                return baseline | battery | motion
            case .pointer:
                return baseline | battery | (optical ? mouse : 0)
            }
        }
    }

    /// Fixed LTK halves the protocol expects during bonding (each prefixed
    /// with 0x00). The controller stores host MAC + this key so a button
    /// press wakes it advertising toward that host.
    package static let pairLTK1 = Data([0x00, 0xEA, 0xBD, 0x47, 0x13, 0x89, 0x35, 0x42,
                                0xC6, 0x79, 0xEE, 0x07, 0xF2, 0x53, 0x2C, 0x6C, 0x31])
    package static let pairLTK2 = Data([0x00, 0x40, 0xB0, 0x8A, 0x5F, 0xCD, 0x1F, 0x9B,
                                0x41, 0x12, 0x5C, 0xAC, 0xC6, 0x3F, 0x38, 0xA0, 0x73])

    // MARK: - Memory map

    package enum Address {
        package static let controllerInfo: UInt32 = 0x0001_3000
        package static let factoryStick1: UInt32 = 0x0001_30A8
        package static let factoryStick2: UInt32 = 0x0001_30E8
        package static let userStick1: UInt32 = 0x001F_C042
        package static let userStick2: UInt32 = 0x001F_C062
        package static let gcTriggers: UInt32 = 0x0001_3140
    }

    /// Player-LED bit patterns matching the console, players 1-8.
    package static let ledPatterns: [UInt8] = [0x01, 0x03, 0x07, 0x0F, 0x09, 0x05, 0x0D, 0x06]

    // MARK: - Buttons (32-bit LE bitmask, report bytes 4..8)

    package typealias Buttons = Switch2Buttons

    /// Stable names for every remappable control, in UI display order.
    /// ZL/ZR are bits like everything else (digital triggers derive from
    /// them), so button remapping covers them naturally.
    package static let namedButtons: [(name: String, button: Buttons)] = [
        ("A", .a), ("B", .b), ("X", .x), ("Y", .y),
        ("D-pad Up", .dpadUp), ("D-pad Down", .dpadDown),
        ("D-pad Left", .dpadLeft), ("D-pad Right", .dpadRight),
        ("L", .l), ("R", .r), ("ZL", .zl), ("ZR", .zr),
        ("Minus", .minus), ("Plus", .plus),
        ("Home", .home), ("Capture", .capture), ("C", .c),
        ("L-stick click", .lStick), ("R-stick click", .rStick),
        ("GL", .gl), ("GR", .gr),
        ("SL (left unit)", .slL), ("SR (left unit)", .srL),
        ("SL (right unit)", .slR), ("SR (right unit)", .srR),
    ]

    package static func button(named name: String) -> Buttons? {
        namedButtons.first { $0.name == name }?.button
    }

    // MARK: - Helpers

    package static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard data.count >= offset + 2 else { return 0 }
        return UInt16(data[data.startIndex + offset])
            | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    package static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        var v: UInt32 = 0
        for i in (0..<4).reversed() {
            v = v << 8 | UInt32(data[data.startIndex + offset + i])
        }
        return v
    }

    package static func s16(_ data: Data, _ offset: Int) -> Int16 {
        Int16(bitPattern: u16(data, offset))
    }

    /// Decode 3 packed bytes into two 12-bit (0...4095) stick axis values.
    package static func stickXY(_ data: Data, _ offset: Int) -> (UInt16, UInt16) {
        guard data.count >= offset + 3 else { return (2048, 2048) }
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let value = b0 | b1 << 8 | b2 << 16
        return (UInt16(value & 0xFFF), UInt16(value >> 12))
    }

    /// Frame a controller command (the shared 0x91 protocol).
    /// Frame a command. `flag` is header byte 2 — 0x01 in all sniffed
    /// Bluetooth traffic (the default); NFC captures over USB show 0x00,
    /// so experiments can override it to replicate console traffic exactly.
    package static func buildCommand(_ command: UInt8, _ subcommand: UInt8,
                             flag: UInt8 = 0x01,
                             data: Data = Data()) -> Data {
        var buf = Data([command, 0x91, flag, subcommand, 0x00,
                        UInt8(data.count), 0x00, 0x00])
        buf.append(data)
        return buf
    }

    /// Payload for a memory read (max 0x4F bytes per read).
    package static func memoryReadPayload(length: UInt8, address: UInt32) -> Data {
        var buf = Data([length, 0x7E, 0x00, 0x00])
        withUnsafeBytes(of: address.littleEndian) { buf.append(contentsOf: $0) }
        return buf
    }

    // MARK: - Advertisement parsing

    /// Parse Nintendo manufacturer data (without the company-id prefix, as
    /// CoreBluetooth delivers it keyed by company id... note: CoreBluetooth
    /// actually delivers the FULL manufacturer blob including the 2-byte
    /// company id; callers must strip it first).
    /// Returns nil unless this is a supported Switch 2 controller.
    package struct AdvertisementInfo {
        package let model: Model
        /// Host MAC the controller will wake for (big-endian integer);
        /// 0 means pairing mode (Sync held).
        package let reconnectHost: UInt64
        package var isPairing: Bool { reconnectHost == 0 }
    }

    package static func parseAdvertisement(manufacturerData manu: Data) -> AdvertisementInfo? {
        // Layout (after 2-byte company id): [0]... vid @3..5, pid @5..7,
        // reconnect host MAC @10..16 — matching the Python bridge offsets
        // into the post-company-id payload.
        guard manu.count >= 16 else { return nil }
        let vid = u16(manu, 3)
        let pid = u16(manu, 5)
        guard vid == nintendoVendorID, let model = Model(rawValue: pid) else {
            return nil
        }
        var host: UInt64 = 0
        for i in 0..<6 {  // bytes 10..16, little-endian per protocol decodeu
            host |= UInt64(manu[manu.startIndex + 10 + i]) << (8 * i)
        }
        return AdvertisementInfo(model: model, reconnectHost: host)
    }

    // MARK: - Controller info block

    package struct ControllerInfo: Sendable {
        package let serialNumber: String
        package let vendorID: UInt16
        package let productID: UInt16
        /// Body and button colors (RGB), when present in the info block.
        package let bodyColor: (UInt8, UInt8, UInt8)
        package let buttonColor: (UInt8, UInt8, UInt8)

        package var model: Model? { Model(rawValue: productID) }

        package init(serialNumber: String, vendorID: UInt16, productID: UInt16,
                     bodyColor: (UInt8, UInt8, UInt8), buttonColor: (UInt8, UInt8, UInt8)) {
            self.serialNumber = serialNumber; self.vendorID = vendorID; self.productID = productID
            self.bodyColor = bodyColor; self.buttonColor = buttonColor
        }

        package init?(memoryBlock data: Data) {
            guard data.count >= 0x25 else { return nil }
            let serialBytes = data.subdata(in: data.startIndex + 2 ..< data.startIndex + 16)
            serialNumber = String(bytes: serialBytes.prefix(while: { $0 != 0 }),
                                  encoding: .utf8) ?? "?"
            vendorID = Switch2.u16(data, 18)
            productID = Switch2.u16(data, 20)
            func rgb(_ o: Int) -> (UInt8, UInt8, UInt8) {
                let s = data.startIndex
                guard data.count > o + 2 else { return (128, 128, 128) }
                return (data[s + o], data[s + o + 1], data[s + o + 2])
            }
            bodyColor = rgb(0x19)     // colors[0] per protocol map (25..28)
            buttonColor = rgb(0x1C)   // colors[1] (28..31)
        }
    }

    // MARK: - Stick calibration

    package struct StickCalibration: Sendable {
        package let center: (x: Double, y: Double)
        package let maxRange: (x: Double, y: Double)
        package let minRange: (x: Double, y: Double)

        package init(data: Data) {
            let c = Switch2.stickXY(data, 0)
            let mx = Switch2.stickXY(data, 3)
            let mn = Switch2.stickXY(data, 6)
            center = (Double(c.0), Double(c.1))
            maxRange = (Double(mx.0), Double(mx.1))
            minRange = (Double(mn.0), Double(mn.1))
        }

        /// Memory is not necessarily usable calibration: an erased, truncated,
        /// or zero-span block must fall back to factory/nominal calibration,
        /// not turn a stick into a permanently neutral axis.
        package init?(validatedData data: Data) {
            guard data.count >= 9, !Self.isBlank(data) else { return nil }
            self.init(data: data)
            guard center.x > 0, center.x < 4095,
                  center.y > 0, center.y < 4095,
                  maxRange.x > 0, maxRange.y > 0,
                  minRange.x > 0, minRange.y > 0 else { return nil }
        }

        /// Map a raw stick pair to -1...1 per axis, with deadzone.
        package func apply(_ raw: (UInt16, UInt16), deadzone: Double = 0) -> (Double, Double) {
            func axis(_ value: Double, _ center: Double,
                      _ maxAbs: Double, _ minAbs: Double) -> Double {
                let signed = value - center
                if signed > deadzone {
                    return maxAbs > 0 ? min(signed / maxAbs, 1) : 0
                }
                if signed < -deadzone {
                    return minAbs > 0 ? -min(-signed / minAbs, 1) : 0
                }
                return 0
            }
            return (axis(Double(raw.0), center.x, maxRange.x, minRange.x),
                    axis(Double(raw.1), center.y, maxRange.y, minRange.y))
        }

        /// The user-calibration slots read 0xFFFFFF when empty.
        package static func isBlank(_ data: Data) -> Bool {
            data.count >= 3 && data.prefix(3).allSatisfy { $0 == 0xFF }
        }
    }

    // MARK: - Input report (63-byte notification)

    package struct InputReport: Sendable {
        package let timestamp: UInt32
        package let buttons: Buttons
        package let leftStickRaw: (UInt16, UInt16)
        package let rightStickRaw: (UInt16, UInt16)
        package let batteryMillivolts: UInt16
        package let gyro: (Int16, Int16, Int16)
        package let accel: (Int16, Int16, Int16)
        package let leftTriggerRaw: UInt8
        package let rightTriggerRaw: UInt8
        /// Optical mouse (Joy-Con 2, feature 0x10): free-running absolute
        /// counters that wrap mod 2^16 — diff consecutive reports for deltas.
        package let mouseX: UInt16
        package let mouseY: UInt16
        /// Surface quality; low = good tracking (ndeadly: "roughness").
        package let surfaceQuality: UInt16
        /// Lift-off distance; 0 = no surface reference.
        package let liftDistance: UInt16
        /// Magnetometer (feature 0x80): AK09919, 0.15 µT/LSB.
        package let mag: (Int16, Int16, Int16)
        /// Charge state byte (@0x21) and battery current (@0x22, feature
        /// 0x20; signed — positive while charging).
        package let chargeState: UInt8
        package let batteryCurrent: Int16
        /// IMU die temperature (@0x2E): °C ≈ 25 + raw/127 (Switch2Connect).
        package let temperatureRaw: Int16

        package init?(data: Data) {
            guard data.count >= 0x3C else { return nil }
            timestamp = Switch2.u32(data, 0)
            buttons = Buttons(rawValue: Switch2.u32(data, 4))
            leftStickRaw = Switch2.stickXY(data, 10)
            rightStickRaw = Switch2.stickXY(data, 13)
            mouseX = Switch2.u16(data, 0x10)
            mouseY = Switch2.u16(data, 0x12)
            surfaceQuality = Switch2.u16(data, 0x14)
            liftDistance = Switch2.u16(data, 0x16)
            mag = (Switch2.s16(data, 0x19), Switch2.s16(data, 0x1B), Switch2.s16(data, 0x1D))
            batteryMillivolts = Switch2.u16(data, 0x1F)
            chargeState = data.count > 0x21 ? data[data.startIndex + 0x21] : 0
            batteryCurrent = Switch2.s16(data, 0x22)
            temperatureRaw = Switch2.s16(data, 0x2E)
            gyro = (Switch2.s16(data, 0x36), Switch2.s16(data, 0x38), Switch2.s16(data, 0x3A))
            accel = (Switch2.s16(data, 0x30), Switch2.s16(data, 0x32), Switch2.s16(data, 0x34))
            leftTriggerRaw = data.count > 0x3C ? data[data.startIndex + 0x3C] : 0
            rightTriggerRaw = data.count > 0x3D ? data[data.startIndex + 0x3D] : 0
        }
    }

    // MARK: - HD rumble

    /// One HD-rumble waveform sample (packed 5-byte little-endian field).
    package struct Vibration: Sendable {
        package var lfFreq: UInt16 = 0x0E1
        package var lfAmp: UInt16 = 0
        package var hfFreq: UInt16 = 0x1E1
        package var hfAmp: UInt16 = 0

        package init(lfFreq: UInt16 = 0x0E1, lfAmp: UInt16 = 0,
                     hfFreq: UInt16 = 0x1E1, hfAmp: UInt16 = 0) {
            self.lfFreq = lfFreq; self.lfAmp = lfAmp
            self.hfFreq = hfFreq; self.hfAmp = hfAmp
        }

        /// Resonant low band; drive amplitude only (tuning from the bridge).
        package static func waveform(strong: Double, weak: Double) -> Vibration {
            let strong = strong.isFinite ? max(0, min(1, strong)) : 0
            let weak = weak.isFinite ? max(0, min(1, weak)) : 0
            let mag = min(1.0, strong + weak * 0.5)
            return Vibration(lfFreq: 0x0E1, lfAmp: UInt16(mag * Double(0x3FF)))
        }

        /// A pure tone on the low band of the voice-coil actuator.
        ///
        /// The 9-bit frequency field carries direct Hz (cross-checked with
        /// console USB captures: the idle frame E1 00 10 1E 00 encodes
        /// 225 Hz, and live console traffic shows values like 406/499 Hz),
        /// so the playable range is 1...511 Hz — about the two octaves
        /// around middle C. `amp` maps 0...1 onto the 10-bit amplitude.
        package static func tone(freqHz: Int, amp: Double) -> Vibration {
            let amplitude = amp.isFinite ? min(1.0, max(0, amp)) : 0
            return Vibration(lfFreq: UInt16(min(511, max(1, freqHz))),
                             lfAmp: UInt16(amplitude * Double(0x3FF)))
        }

        package func packed() -> Data {
            var v: UInt64 = 0
            v |= UInt64(lfFreq & 0x1FF)
            v |= UInt64(lfAmp & 0x3FF) << 10
            v |= UInt64(hfFreq & 0x1FF) << 20
            v |= UInt64(hfAmp & 0x3FF) << 30
            var buf = Data()
            withUnsafeBytes(of: v.littleEndian) { buf.append(contentsOf: $0.prefix(5)) }
            return buf
        }
    }

    /// A complete motor intent. Keep both channels together when replacing a
    /// queued intent, including stop/expiry, so one motor cannot outlive the other.
    package struct MotorVibration: Sendable {
        package var left: Vibration
        package var right: Vibration

        package init(left: Vibration, right: Vibration) {
            self.left = left
            self.right = right
        }

        /// Tones and other single-sample callers intentionally drive both motors.
        package init(_ sample: Vibration) { self.init(left: sample, right: sample) }

        package static let stopped = MotorVibration(Vibration())

        package static func waveform(strong: Double, weak: Double, model: Model) -> MotorVibration {
            guard model == .proController2 else {
                // Preserve the established single-actuator Joy-Con mix.
                return MotorVibration(.waveform(strong: strong, weak: weak))
            }
            // Pro: strong -> left, weak -> right. Both use the existing resonant
            // waveform; do not collapse two independent game amplitudes to mono.
            return MotorVibration(left: .waveform(strong: strong, weak: 0),
                                  right: .waveform(strong: weak, weak: 0))
        }
    }

    /// Backward-compatible uniform tone/experiment packet.
    package static func motorPacket(_ vib: Vibration, packetID: UInt8, model: Model) -> Data {
        motorPacket(MotorVibration(vib), packetID: packetID, model: model)
    }

    /// Three identical sub-frames per motor; Pro has separate L then R blocks.
    /// The sequence nibble belongs to the whole write and wraps modulo 16.
    package static func motorPacket(_ motors: MotorVibration, packetID: UInt8, model: Model) -> Data {
        func block(_ sample: Vibration) -> Data {
            var data = Data([0x50 | (packetID & 0x0F)])
            let packed = sample.packed()
            for _ in 0..<3 { data.append(packed) }
            return data
        }
        var payload = Data([0x00])
        payload.append(block(motors.left))
        if model == .proController2 { payload.append(block(motors.right)) }
        return payload
    }
}
