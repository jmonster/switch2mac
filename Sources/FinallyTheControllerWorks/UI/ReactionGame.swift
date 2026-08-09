// ReactionGame.swift
// The reaction-draft party game: all connected controllers "line up," a buzz
// fires at a random time, and each player races to press a button. Finish
// order (fastest reaction first) becomes the player-slot assignment.
//
// Fairness: a press BEFORE the buzz is a false start — that player is moved
// to the back of the order. Reaction timing uses the engine's full-rate
// (~66 Hz) rising-edge callback with CFAbsoluteTime timestamps, not the
// 10 Hz UI feed, so millisecond differences are real.

import SwiftUI

@MainActor
final class ReactionGame: ObservableObject {

    enum Phase: Equatable {
        case lobby              // waiting to start
        case arming             // random delay before the buzz — DON'T press
        case go                 // buzz fired — press now!
        case results
    }

    struct Result: Identifiable {
        let id: String
        let name: String
        var reactionMs: Double?     // nil until they press
        var falseStart = false
    }

    @Published private(set) var phase: Phase = .lobby
    @Published private(set) var results: [Result] = []
    @Published private(set) var countdownHint = ""

    private weak var engine: BridgeEngine?
    private var buzzTime: TimeInterval = 0
    private var armWork: DispatchWorkItem?
    private var order: [String] = []            // finish order as they press

    func attach(_ engine: BridgeEngine) {
        self.engine = engine
    }

    var participantCount: Int { results.count }

    // MARK: - Flow

    func openLobby() {
        phase = .lobby
        refreshLobby()
    }

    func refreshLobby() {
        guard phase == .lobby else { return }
        let parts = engine?.participants() ?? []
        results = parts.map { Result(id: $0.id, name: $0.name) }
    }

    func start() {
        guard let engine, !results.isEmpty else { return }
        // Reset scores; keep participants.
        results = results.map { Result(id: $0.id, name: $0.name) }
        order = []
        phase = .arming
        countdownHint = "Get ready… don't press until you feel the buzz!"

        engine.onParticipantPress = { [weak self] id, time in
            Task { @MainActor in self?.handlePress(id: id, time: time) }
        }

        // Random 2–6 s arm delay. (App context: Date/random are fine here.)
        let delay = Double.random(in: 2.0...6.0)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .arming else { return }
            self.buzzTime = engine.buzzAll()
            self.phase = .go
            self.countdownHint = "PRESS!"
        }
        armWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handlePress(id: String, time: TimeInterval) {
        guard let idx = results.firstIndex(where: { $0.id == id }) else { return }

        switch phase {
        case .arming:
            // Jumped the gun.
            if !results[idx].falseStart && results[idx].reactionMs == nil {
                results[idx].falseStart = true
                engine?.buzz(id: id)   // a scolding buzz
            }
        case .go:
            guard results[idx].reactionMs == nil, !results[idx].falseStart else { return }
            results[idx].reactionMs = (time - buzzTime) * 1000
            if !order.contains(id) { order.append(id) }
            if everyoneDone { finish() }
        default:
            break
        }
    }

    private var everyoneDone: Bool {
        results.allSatisfy { $0.reactionMs != nil || $0.falseStart }
    }

    func finish() {
        armWork?.cancel()
        engine?.onParticipantPress = nil

        // Rank: valid reactions fastest-first, then false starts at the back.
        let ranked = results.sorted { a, b in
            switch (a.reactionMs, b.reactionMs) {
            case let (ra?, rb?): return ra < rb
            case (_?, nil): return true
            case (nil, _?): return false
            default: return false
            }
        }
        results = ranked
        phase = .results
    }

    func applyAssignment() {
        let ids = results.map { $0.id }
        engine?.assignPlayerOrder(ids)
        phase = .lobby
    }

    func cancel() {
        armWork?.cancel()
        engine?.onParticipantPress = nil
        phase = .lobby
        refreshLobby()
    }
}

struct ReactionGameView: View {
    @ObservedObject var game: ReactionGame
    @ObservedObject var engine: BridgeEngine

    var body: some View {
        VStack(spacing: 16) {
            Text("Reaction Draft")
                .font(.largeTitle.bold())
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            switch game.phase {
            case .lobby:
                lobby
            case .arming, .go:
                playfield
            case .results:
                resultsView
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 420)
        .onChange(of: engine.controllers.count) { _, _ in game.refreshLobby() }
        .onAppear { game.attach(engine); game.openLobby() }
    }

    private var subtitle: String {
        switch game.phase {
        case .lobby: return "Everyone grab a controller. When the buzz hits, be the fastest to press any button."
        case .arming: return "Wait for it…"
        case .go: return "PRESS ANY BUTTON!"
        case .results: return "Finish order becomes Player 1 → \(game.participantCount)."
        }
    }

    private var lobby: some View {
        VStack(spacing: 12) {
            if game.results.isEmpty {
                Text("No controllers connected — wake some up to join.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(game.results) { r in
                    HStack {
                        Image(systemName: "gamecontroller.fill")
                        Text(r.name)
                        Spacer()
                        Text("ready").foregroundStyle(.green)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                }
            }
            Button("Start") { game.start() }
                .buttonStyle(.borderedProminent)
                .disabled(game.results.count < 1)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var playfield: some View {
        VStack(spacing: 16) {
            Text(game.phase == .go ? "PRESS!" : "…")
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundStyle(game.phase == .go ? .green : .orange)
            Text(game.countdownHint)
            ForEach(game.results) { r in
                HStack {
                    Text(r.name)
                    Spacer()
                    if r.falseStart {
                        Text("false start").foregroundStyle(.red)
                    } else if let ms = r.reactionMs {
                        Text("\(Int(ms)) ms").foregroundStyle(.green).monospacedDigit()
                    } else {
                        Text("…").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
            }
            Button("Cancel") { game.cancel() }
        }
    }

    private var resultsView: some View {
        VStack(spacing: 12) {
            ForEach(Array(game.results.enumerated()), id: \.element.id) { pair in
                ResultRow(rank: pair.offset, result: pair.element)
            }
            HStack {
                Button("Play again") { game.openLobby() }
                Button("Assign these player slots") { game.applyAssignment() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct ResultRow: View {
    let rank: Int
    let result: ReactionGame.Result

    var body: some View {
        HStack {
            Text("P\(rank + 1)")
                .font(.title2.bold())
                .frame(width: 44)
                .foregroundStyle(.tint)
            Text(result.name)
            Spacer()
            if result.falseStart {
                Text("false start").foregroundStyle(.red)
            } else if let ms = result.reactionMs {
                Text("\(Int(ms)) ms").monospacedDigit()
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(rank == 0 ? Color.yellow.opacity(0.18) : Color.secondary.opacity(0.1)))
    }
}
