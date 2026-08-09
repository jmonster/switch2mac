// ChallengeGames.swift
// A small arcade of sensor challenges for multiple controllers — each turns
// the IMU/compass into a scored competition:
//   * Steady Hands  — hold it as still as possible (lowest total motion).
//   * True North    — point at where the controller thinks north is
//                     (smallest heading error from 0°).
//   * Perfectly Level — hold it flat (smallest average tilt).
//   * Spin Master   — spin it as fast as you can (highest peak rotation).
//
// Each challenge runs a fixed measurement window over the engine's full-rate
// per-participant sensor stream, accumulates one metric per controller, then
// ranks everyone.

import SwiftUI

enum Challenge: String, CaseIterable, Identifiable {
    case steady = "Steady Hands"
    case north = "True North"
    case level = "Perfectly Level"
    case spin = "Spin Master"

    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .steady: return "Hold your controller as still as a statue. Least motion wins."
        case .north: return "Point your controller where you think its north is. Closest wins."
        case .level: return "Hold it perfectly flat and level. Least tilt wins."
        case .spin: return "Spin your controller as fast as you can! Fastest wins."
        }
    }

    var seconds: Double {
        switch self {
        case .steady, .level: return 5
        case .north: return 4
        case .spin: return 4
        }
    }

    /// Lower metric is better for still/level/north; higher for spin.
    var lowerIsBetter: Bool { self != .spin }

    func unit(_ value: Double) -> String {
        switch self {
        case .steady: return String(format: "%.0f", value)
        case .north: return String(format: "%.0f° off", value)
        case .level: return String(format: "%.1f° tilt", value)
        case .spin: return String(format: "%.0f °/s", value)
        }
    }
}

@MainActor
final class ChallengeCoordinator: ObservableObject {

    enum Phase: Equatable { case lobby, countdown, measuring, results }

    struct Score: Identifiable {
        let id: String
        let name: String
        var metric: Double
        var samples: Int
    }

    @Published var challenge: Challenge = .steady
    @Published private(set) var phase: Phase = .lobby
    @Published private(set) var scores: [Score] = []
    @Published private(set) var countdownValue = 3
    @Published private(set) var timeLeft = 0.0

    private weak var engine: BridgeEngine?
    private var accum: [String: (metric: Double, samples: Int, peak: Double)] = [:]
    private var work: [DispatchWorkItem] = []

    func attach(_ engine: BridgeEngine) { self.engine = engine }

    func openLobby() {
        cancelTimers()
        engine?.onParticipantState = nil
        phase = .lobby
        let parts = engine?.participants() ?? []
        scores = parts.map { Score(id: $0.id, name: $0.name, metric: 0, samples: 0) }
    }

    func refreshLobby() {
        guard phase == .lobby else { return }
        openLobby()
    }

    func start() {
        guard let engine, !scores.isEmpty else { return }
        accum = [:]
        phase = .countdown
        countdownValue = 3
        tickCountdown()

        engine.onParticipantState = { [weak self] id, state in
            Task { @MainActor in self?.sample(id: id, state: state) }
        }
    }

    private func tickCountdown() {
        guard countdownValue > 0 else {
            beginMeasuring()
            return
        }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.countdownValue -= 1
            if self.countdownValue == 0 { self.engine?.buzzAll(strong: 0.6, durationMs: 120) }
            self.tickCountdown()
        }
        work.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    private func beginMeasuring() {
        phase = .measuring
        timeLeft = challenge.seconds
        let end = DispatchWorkItem { [weak self] in self?.finish() }
        work.append(end)
        DispatchQueue.main.asyncAfter(deadline: .now() + challenge.seconds, execute: end)

        // Countdown display.
        func tick() {
            guard phase == .measuring else { return }
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .measuring else { return }
                self.timeLeft = max(0, self.timeLeft - 0.1)
                tick()
            }
            work.append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: w)
        }
        tick()
    }

    private func sample(id: String, state: ControllerState) {
        guard phase == .measuring else { return }
        var a = accum[id] ?? (0, 0, 0)
        switch challenge {
        case .steady:
            // Total rotational + linear jitter magnitude.
            let g = gyroMagnitude(state)
            let accelJitter = abs(Double(state.accel.2) - 4096) / 100  // deviation from 1g up
            a.metric += g + accelJitter
        case .spin:
            a.peak = max(a.peak, gyroDegPerSec(state))
        case .level:
            let tilt = tiltDegrees(state)
            a.metric += tilt
        case .north:
            // Snapshot the latest heading; metric = |heading - 0| each sample,
            // averaged so brief wobble doesn't dominate.
            if let h = heading(id: id, state: state) {
                let err = min(h, 360 - h)
                a.metric += err
            }
        }
        a.samples += 1
        accum[id] = a
    }

    private func finish() {
        cancelTimers()
        engine?.onParticipantState = nil

        scores = scores.map { s in
            let a = accum[s.id] ?? (0, 0, 0)
            var value: Double
            switch challenge {
            case .spin: value = a.peak
            case .steady: value = a.samples > 0 ? a.metric / Double(a.samples) * 100 : 999
            case .level, .north: value = a.samples > 0 ? a.metric / Double(a.samples) : 999
            }
            return Score(id: s.id, name: s.name, metric: value, samples: a.samples)
        }
        .sorted { challenge.lowerIsBetter ? $0.metric < $1.metric : $0.metric > $1.metric }

        phase = .results
        if let winner = scores.first { engine?.buzz(id: winner.id, durationMs: 400) }
    }

    func cancel() {
        cancelTimers()
        engine?.onParticipantState = nil
        openLobby()
    }

    private func cancelTimers() {
        work.forEach { $0.cancel() }
        work = []
    }

    // MARK: - Sensor math

    private func gyroMagnitude(_ s: ControllerState) -> Double {
        let x = Double(s.gyro.0), y = Double(s.gyro.1), z = Double(s.gyro.2)
        return (x*x + y*y + z*z).squareRoot() / 1000
    }

    /// Raw gyro → °/s. Switch IMU full-scale ≈ 2000 °/s over ±32768.
    private func gyroDegPerSec(_ s: ControllerState) -> Double {
        let x = Double(s.gyro.0), y = Double(s.gyro.1), z = Double(s.gyro.2)
        return (x*x + y*y + z*z).squareRoot() * 2000 / 32768
    }

    private func tiltDegrees(_ s: ControllerState) -> Double {
        let ax = Double(s.accel.0), ay = Double(s.accel.1), az = Double(s.accel.2)
        let horizontal = (ax*ax + ay*ay).squareRoot()
        return atan2(horizontal, abs(az)) * 180 / .pi
    }

    private func heading(id: String, state: ControllerState) -> Double? {
        SmoothedMotion.tiltCompensatedHeading(
            mag: state.mag,
            ax: Double(state.accel.0), ay: Double(state.accel.1), az: Double(state.accel.2),
            serial: id, previous: nil)
    }
}

struct ChallengeView: View {
    @ObservedObject var coordinator: ChallengeCoordinator
    @ObservedObject var engine: BridgeEngine

    var body: some View {
        VStack(spacing: 16) {
            Text("Sensor Challenges").font(.largeTitle.bold())

            switch coordinator.phase {
            case .lobby: lobby
            case .countdown: countdown
            case .measuring: measuring
            case .results: results
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 460)
        .onChange(of: engine.controllers.count) { _, _ in coordinator.refreshLobby() }
        .onAppear { coordinator.attach(engine); coordinator.openLobby() }
    }

    private var lobby: some View {
        VStack(spacing: 14) {
            Picker("Challenge", selection: $coordinator.challenge) {
                ForEach(Challenge.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(coordinator.challenge.blurb)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            if coordinator.scores.isEmpty {
                Text("No controllers connected — wake some up to play.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.scores) { s in
                    HStack {
                        Image(systemName: "gamecontroller.fill")
                        Text(s.name)
                        Spacer()
                        Text("ready").foregroundStyle(.green)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                }
            }
            Button("Start") { coordinator.start() }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.scores.isEmpty)
        }
    }

    private var countdown: some View {
        VStack(spacing: 12) {
            Text("\(coordinator.countdownValue == 0 ? "GO!" : "\(coordinator.countdownValue)")")
                .font(.system(size: 80, weight: .heavy, design: .rounded))
                .foregroundStyle(.tint)
            Text(coordinator.challenge.blurb).foregroundStyle(.secondary)
        }
    }

    private var measuring: some View {
        VStack(spacing: 12) {
            Text(String(format: "%.1fs", coordinator.timeLeft))
                .font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())
            ProgressView(value: coordinator.timeLeft, total: coordinator.challenge.seconds)
                .frame(width: 260)
            Text(coordinator.challenge.blurb).foregroundStyle(.secondary)
        }
    }

    private var results: some View {
        VStack(spacing: 12) {
            ForEach(Array(coordinator.scores.enumerated()), id: \.element.id) { pair in
                ChallengeRow(rank: pair.offset, score: pair.element,
                             unit: coordinator.challenge.unit(pair.element.metric))
            }
            HStack {
                Button("Play again") { coordinator.openLobby() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct ChallengeRow: View {
    let rank: Int
    let score: ChallengeCoordinator.Score
    let unit: String

    var body: some View {
        HStack {
            Text(rank == 0 ? "🏆" : "\(rank + 1)")
                .font(.title2.bold())
                .frame(width: 44)
            Text(score.name)
            Spacer()
            Text(unit).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(rank == 0 ? Color.yellow.opacity(0.18) : Color.secondary.opacity(0.1)))
    }
}
