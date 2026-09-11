import Foundation

@main enum PolicyTests {
    static func main() throws {
        for model in Switch2.Model.allCases {
            for backend in OutputBackend.allCases {
                let caps = OutputCapabilities(model: model, backend: backend)
                precondition(caps.directRumble == (model != .nsoGameCube))
                precondition(caps.gameRumble == (model != .nsoGameCube && [.sdl, .browser].contains(backend)))
                precondition(caps.analogTravel == (model == .nsoGameCube && backend != .retroarch))
                precondition(caps.independentTriggerClicks == (model == .nsoGameCube && backend == .sdl))
                precondition(caps.motion == (backend == .sdl))
                precondition(caps.explanation.contains("experiments"))
            }
        }
        for backend in OutputBackend.allCases {
            precondition(backend.guideURL.host == "github.com")
            let result = OutputHealth(backend: backend, state: .unavailable, affectedSlots: [0, 2])
            precondition(!result.guidance.isEmpty)
            let decoded = try JSONDecoder().decode(OutputHealth.self, from: JSONEncoder().encode(result))
            precondition(decoded == result)
        }
        precondition(OutputHealth(backend: .retroarch, state: .sendingUnconfirmed).summary.contains("unconfirmed"))
        print("PASS all 16 model/backend capabilities and typed health encoding")
    }
}
