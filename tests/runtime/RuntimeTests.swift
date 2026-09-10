import Foundation

@main enum RuntimeTests {
    static func main() {
        for value in [-1, 65536, Int.max] {
            precondition(KeySpec(dictionary: ["keyCode":value,"modifiers":0,"label":"x"]) == nil)
        }
        precondition(KeySpec(dictionary: ["keyCode":0,"modifiers":-1,"label":"x"]) == nil)
        let spec = KeySpec(keyCode: 4, modifiers: 0, label: "h")
        let config = ControllerConfiguration(["keyMap":["A":spec.asDictionary,"B":spec.asDictionary]])
        var events: [(UInt16,Bool)] = []
        let mapper = KeyboardMapper { events.append(($0.keyCode,$1)) }
        mapper.updateContext(app: "game", permission: true)
        _ = mapper.process(player: 0, configuration: config, buttons: [.a,.b])
        _ = mapper.process(player: 1, configuration: config, buttons: [.a])
        precondition(events.count == 1 && events[0].1)
        _ = mapper.process(player: 0, configuration: config, buttons: [.b])
        mapper.reset(player: 0)
        precondition(events.count == 1, "Another player still owns the key")
        mapper.reset(player: 1)
        precondition(events.count == 2 && !events[1].1)
        _ = mapper.process(player: 0, configuration: config, buttons: [.a])
        mapper.updateContext(app: "other", permission: true)
        precondition(events.count == 4 && !events[3].1, "App switch must release the original binding")
        _ = mapper.process(player: 0, configuration: config, buttons: [.a])
        mapper.updateContext(app: "other", permission: false)
        precondition(events.count == 6 && !events[5].1)
        precondition(mapper.process(player: 0, configuration: config, buttons: [.a]).isEmpty)
        let none = ControllerConfiguration(["keyMap":["A":spec.asDictionary], "keyMapByApp":["other":[:]]])
        precondition(none.keys(for: "other").isEmpty && !none.keys(for: "game").isEmpty)
        var state = ControllerState()
        state.leftStick = (0.1, 0.1)
        let shaped = ControllerConfiguration(["deadzone":0.2, "stickCenterL":[0.1,0.1]]).apply(state, analogTriggers: false)
        precondition(shaped.leftStick == (0,0), "Center correction belongs before deadzone")
        state.leftStick = (Double.nan, Double.infinity)
        let safe = ControllerConfiguration(["deadzone":Double.nan,"triggerThreshold":Double.infinity]).apply(state, analogTriggers: true)
        precondition(safe.leftStick == (0,0))
        state.buttons = [.zl]; state.leftTrigger = 255
        ControllerConfiguration.suppress(.zl, in: &state, analogTriggers: false)
        precondition(state.buttons.isEmpty && state.leftTrigger == 0)
        state.buttons = [.zl]; state.leftTrigger = 128
        ControllerConfiguration.suppress(.zl, in: &state, analogTriggers: true)
        precondition(state.buttons.isEmpty && state.leftTrigger == 128)
        print("PASS runtime configuration, held-key ownership, context cleanup, finite axes and trigger suppression")
    }
}
