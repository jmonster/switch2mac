import Switch2Kit

// Dashboard policy, not a stable controller capability. The experimental
// companion can run a finite GameCube preset diagnostic, but the stable kit
// deliberately does not promise duration-controlled GameCube rumble.
extension Switch2ControllerModel {
    var hasDirectRumbleTest: Bool {
        capabilities.contains(.rumble) || self == .nsoGameCube
    }
}
