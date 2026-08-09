// MotionVisualizer.swift
// Turns the raw motion numbers into instruments:
//  * Attitude bubble — pitch/roll from the accelerometer (gravity vector),
//    like a bullseye spirit level: the dot is where "down" is.
//  * Gyro bars — rotation-rate magnitude per axis, so any twitch is visible.
//  * Compass — heading from the magnetometer after hard-iron calibration
//    (wave the controller in a figure-8 during the 10 s calibration window;
//    the min/max midpoints become the stored per-controller bias).

import SwiftUI

struct MotionVisualizer: View {
    let state: ControllerState?
    let serial: String

    @ObservedObject private var settings = ControllerSettings.shared
    @State private var calibrating = false
    @State private var calibrationEnd = Date()
    @State private var minSample = (x: Double.infinity, y: Double.infinity, z: Double.infinity)
    @State private var maxSample = (x: -Double.infinity, y: -Double.infinity, z: -Double.infinity)

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 24) {
                AttitudeBubble(accel: state?.accel)
                GyroBars(gyro: state?.gyro)
                CompassDial(heading: heading)
            }
            HStack(spacing: 10) {
                Button(calibrating ? "Wave it in a figure-8…" : "Calibrate compass") {
                    startCalibration()
                }
                .disabled(calibrating)
                .controlSize(.small)
                if let m = state?.mag {
                    Text("mag \(m.0) \(m.1) \(m.2) · gyro \(state?.gyro.0 ?? 0) \(state?.gyro.1 ?? 0) \(state?.gyro.2 ?? 0)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onChange(of: magKey) { _, _ in
            guard calibrating, let m = state?.mag else { return }
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

    /// Change-detection key for the magnetometer tuple (tuples aren't
    /// Equatable in onChange).
    private var magKey: String {
        guard let m = state?.mag else { return "-" }
        return "\(m.0),\(m.1),\(m.2)"
    }

    private func startCalibration() {
        calibrating = true
        calibrationEnd = Date().addingTimeInterval(10)
        minSample = (.infinity, .infinity, .infinity)
        maxSample = (-.infinity, -.infinity, -.infinity)
        bridgeLog(.info, "motion",
                  "compass calibration: wave the controller in a slow figure-8 for 10 seconds")
    }

    /// Heading in degrees from the bias-corrected horizontal field.
    private var heading: Double? {
        guard let m = state?.mag, m != (0, 0, 0) else { return nil }
        let bias = settings.magBias(forSerial: serial) ?? (0, 0, 0)
        let x = Double(m.0) - bias.x
        let y = Double(m.1) - bias.y
        let radians = atan2(y, x)
        return (radians * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// Bullseye level: the dot shows where gravity points.
private struct AttitudeBubble: View {
    let accel: (Int16, Int16, Int16)?

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
        guard let a = accel else { return .zero }
        // Normalize gravity to the disc; 1 g ≈ 4096 raw (typical ±8 g range).
        let scale = 22.0 / 4096.0
        let dx = max(-22, min(22, Double(a.0) * scale))
        let dy = max(-22, min(22, Double(a.1) * scale))
        return CGSize(width: dx, height: dy)
    }
}

/// Rotation-rate magnitude per axis.
private struct GyroBars: View {
    let gyro: (Int16, Int16, Int16)?

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .bottom, spacing: 5) {
                bar(gyro?.0, "x")
                bar(gyro?.1, "y")
                bar(gyro?.2, "z")
            }
            .frame(height: 56, alignment: .bottom)
            Text("spin").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func bar(_ value: Int16?, _ label: String) -> some View {
        let magnitude = min(1.0, abs(Double(value ?? 0)) / 8000.0)
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
