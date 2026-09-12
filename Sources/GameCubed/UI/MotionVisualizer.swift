// MotionVisualizer.swift
// Turns the raw motion numbers into smooth instruments:
//  * Attitude bubble — pitch/roll from the accelerometer (gravity vector),
//    like a bullseye spirit level: the dot is where "down" is.
//  * Gyro bars — rotation-rate magnitude per axis.
//  * Compass — TILT-COMPENSATED heading: the magnetic vector is de-rotated
//    by the accelerometer-derived pitch/roll before atan2, so the needle
//    stays correct even when the controller isn't lying flat.
//
// All displayed values pass through a light exponential smoother
// (SmoothedMotion) so the animations glide instead of jittering, while a
// high smoothing factor keeps them responsive.

import SwiftUI

/// Exponential moving average of the motion channels we display. Updated on
/// the main actor from the ~10 Hz liveStates feed; a display-linked timer is
/// unnecessary because SwiftUI animates between published values.
@MainActor
final class SmoothedMotion: ObservableObject {
    @Published var accel: (x: Double, y: Double, z: Double) = (0, 0, 1)
    @Published var gyroMag: (x: Double, y: Double, z: Double) = (0, 0, 0)
    @Published var heading: Double? = nil

    /// 0..1; higher = snappier, lower = smoother. 0.35 is a good balance.
    private let alpha = 0.35

    func update(_ state: ControllerState?, serial: String) {
        guard let s = state else { return }
        let ax = Double(s.accel.0), ay = Double(s.accel.1), az = Double(s.accel.2)
        accel = (lerp(accel.x, ax), lerp(accel.y, ay), lerp(accel.z, az))
        gyroMag = (lerp(gyroMag.x, abs(Double(s.gyro.0))),
                   lerp(gyroMag.y, abs(Double(s.gyro.1))),
                   lerp(gyroMag.z, abs(Double(s.gyro.2))))
        heading = Self.tiltCompensatedHeading(mag: s.mag, ax: ax, ay: ay, az: az,
                                              serial: serial, previous: heading)
    }

    private func lerp(_ current: Double, _ target: Double) -> Double {
        current + (target - current) * alpha
    }

    /// Tilt-compensated compass heading in degrees, or nil if no field.
    /// Standard AHRS derivation: pitch/roll from gravity, then rotate the
    /// magnetometer vector into the horizontal plane.
    static func tiltCompensatedHeading(mag: (Int16, Int16, Int16),
                                       ax: Double, ay: Double, az: Double,
                                       serial: String,
                                       previous: Double?) -> Double? {
        guard mag != (0, 0, 0) else { return nil }
        let bias = ControllerSettings.shared.magBias(forSerial: serial) ?? (0, 0, 0)
        let mx = Double(mag.0) - bias.x
        let my = Double(mag.1) - bias.y
        let mz = Double(mag.2) - bias.z

        // Normalize gravity → pitch (around x) and roll (around y).
        let norm = (ax*ax + ay*ay + az*az).squareRoot()
        guard norm > 1 else { return previous }
        let axn = ax / norm, ayn = ay / norm
        let pitch = asin(-axn)
        let roll = asin(ayn / cos(pitch))
        guard pitch.isFinite, roll.isFinite else { return previous }

        // De-rotate the magnetic vector into the horizontal plane.
        let xh = mx * cos(pitch) + mz * sin(pitch)
        let yh = mx * sin(roll) * sin(pitch) + my * cos(roll) - mz * sin(roll) * cos(pitch)
        var heading = atan2(yh, xh) * 180 / .pi
        if heading < 0 { heading += 360 }

        // Shortest-path smoothing across the 0/360 wrap.
        if let prev = previous {
            var delta = heading - prev
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            heading = (prev + delta * 0.35 + 360).truncatingRemainder(dividingBy: 360)
        }
        return heading
    }
}

struct MotionVisualizer: View {
    let state: ControllerState?
    let serial: String

    @ObservedObject private var settings = ControllerSettings.shared
    @StateObject private var motion = SmoothedMotion()
    @State private var calibrating = false
    @State private var calibrationEnd = Date()
    @State private var minSample = (x: Double.infinity, y: Double.infinity, z: Double.infinity)
    @State private var maxSample = (x: -Double.infinity, y: -Double.infinity, z: -Double.infinity)

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 28) {
                AttitudeBubble(accel: motion.accel)
                GyroBars(gyro: motion.gyroMag)
                CompassDial(heading: motion.heading)
            }
            Button(calibrating ? "Wave it in a figure-8…" : "Calibrate compass") {
                startCalibration()
            }
            .disabled(calibrating)
            .controlSize(.small)
        }
        .onChange(of: liveKey) { _, _ in
            withAnimation(.easeOut(duration: 0.08)) {
                motion.update(state, serial: serial)
            }
            accumulateCalibration()
        }
    }

    /// Compact change key so onChange fires on every fresh liveState.
    private var liveKey: String {
        guard let s = state else { return "-" }
        return "\(s.accel.0),\(s.accel.1),\(s.mag.0),\(s.gyro.0)"
    }

    private func startCalibration() {
        calibrating = true
        calibrationEnd = Date().addingTimeInterval(10)
        minSample = (.infinity, .infinity, .infinity)
        maxSample = (-.infinity, -.infinity, -.infinity)
        bridgeLog(.info, "motion",
                  "compass calibration: wave the controller in a slow figure-8, "
                  + "rolling it through all orientations, for 10 seconds")
    }

    private func accumulateCalibration() {
        guard calibrating, let m = state?.mag, m != (0, 0, 0) else { return }
        let s = (x: Double(m.0), y: Double(m.1), z: Double(m.2))
        minSample = (min(minSample.x, s.x), min(minSample.y, s.y), min(minSample.z, s.z))
        maxSample = (max(maxSample.x, s.x), max(maxSample.y, s.y), max(maxSample.z, s.z))
        if Date() >= calibrationEnd {
            calibrating = false
            let bias = (x: (minSample.x + maxSample.x) / 2,
                        y: (minSample.y + maxSample.y) / 2,
                        z: (minSample.z + maxSample.z) / 2)
            settings.setMagBias(bias, forSerial: serial)
            bridgeLog(.info, "motion",
                      "compass calibrated: bias \(Int(bias.x)) \(Int(bias.y)) \(Int(bias.z))")
        }
    }
}

/// Bullseye level: the dot shows where gravity points.
private struct AttitudeBubble: View {
    let accel: (x: Double, y: Double, z: Double)

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().strokeBorder(.secondary.opacity(0.4))
                Circle().strokeBorder(.secondary.opacity(0.2))
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(.tint)
                    .frame(width: 10, height: 10)
                    .offset(offset)
            }
            .frame(width: 56, height: 56)
            Text("tilt").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var offset: CGSize {
        // Normalize gravity to the disc; 1 g ≈ 4096 raw (typical ±8 g range).
        let scale = 22.0 / 4096.0
        return CGSize(width: max(-22, min(22, accel.x * scale)),
                      height: max(-22, min(22, accel.y * scale)))
    }
}

/// Rotation-rate magnitude per axis.
private struct GyroBars: View {
    let gyro: (x: Double, y: Double, z: Double)

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .bottom, spacing: 5) {
                bar(gyro.x, "x")
                bar(gyro.y, "y")
                bar(gyro.z, "z")
            }
            .frame(height: 56, alignment: .bottom)
            Text("spin").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func bar(_ value: Double, _ label: String) -> some View {
        let magnitude = min(1.0, value / 8000.0)
        return VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2)
                .fill(magnitude > 0.02 ? Color.accentColor : Color.gray.opacity(0.25))
                .frame(width: 10, height: max(3, 48 * magnitude))
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// Compass rose with a needle at the computed heading.
private struct CompassDial: View {
    let heading: Double?

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().strokeBorder(.secondary.opacity(0.4))
                Text("N").font(.caption2).foregroundStyle(.secondary)
                    .offset(y: -21)
                if let heading {
                    Capsule()
                        .fill(.red)
                        .frame(width: 3, height: 22)
                        .offset(y: -11)
                        .rotationEffect(.degrees(heading))
                    Text("\(Int(heading))°")
                        .font(.system(.caption2, design: .monospaced))
                        .offset(y: 12)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 56, height: 56)
            Text("compass").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
