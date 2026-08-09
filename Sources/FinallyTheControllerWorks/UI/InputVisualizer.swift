// InputVisualizer.swift
// Live input test pad: sticks as crosshair dots, buttons as chips that light
// up, triggers as bars. Fed by BridgeEngine.liveStates at ~10 Hz — enough to
// verify every control without launching a game.

import SwiftUI

struct InputVisualizer: View {
    let state: ControllerState?

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            StickDot(label: "L", x: state?.leftStick.x ?? 0,
                     y: state?.leftStick.y ?? 0,
                     pressed: pressed(.lStick))
            VStack(spacing: 6) {
                buttonRow([("↑", .dpadUp), ("↓", .dpadDown),
                           ("←", .dpadLeft), ("→", .dpadRight)])
                buttonRow([("A", .a), ("B", .b), ("X", .x), ("Y", .y)])
                buttonRow([("L", .l), ("R", .r), ("−", .minus), ("+", .plus)])
                buttonRow([("Home", .home), ("Cap", .capture), ("C", .c),
                           ("GL", .gl), ("GR", .gr)])
                HStack(spacing: 8) {
                    TriggerBar(label: "ZL", value: state?.leftTrigger ?? 0)
                    TriggerBar(label: "ZR", value: state?.rightTrigger ?? 0)
                }
            }
            StickDot(label: "R", x: state?.rightStick.x ?? 0,
                     y: state?.rightStick.y ?? 0,
                     pressed: pressed(.rStick))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func pressed(_ button: Switch2.Buttons) -> Bool {
        state?.buttons.contains(button) ?? false
    }

    private func buttonRow(_ chips: [(String, Switch2.Buttons)]) -> some View {
        HStack(spacing: 6) {
            ForEach(chips, id: \.0) { label, mask in
                Text(label)
                    .font(.system(.caption, design: .rounded).bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(pressed(mask) ? Color.accentColor : Color.gray.opacity(0.2)))
                    .foregroundStyle(pressed(mask) ? .white : .secondary)
            }
        }
    }
}

private struct StickDot: View {
    let label: String
    let x: Double
    let y: Double
    let pressed: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(pressed ? Color.accentColor : .secondary.opacity(0.4),
                              lineWidth: pressed ? 2 : 1)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
                // SwiftUI y grows downward; stick y is up-positive.
                .offset(x: x * 24, y: -y * 24)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .offset(y: 26)
        }
        .frame(width: 64, height: 64)
    }
}

private struct TriggerBar: View {
    let label: String
    let value: UInt8

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(value) / 255)
                }
            }
            .frame(height: 8)
        }
        .frame(width: 90)
    }
}
