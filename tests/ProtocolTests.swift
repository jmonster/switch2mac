import Foundation

@main
enum ProtocolTests {
    static func main() {
        // Synthetic fixtures, not hardware captures. Preserve existing bytes.
        let led = Switch2.buildCommand(0x09, 0x07, data: Data([3, 0, 0, 0]))
        precondition(led == Data([9, 0x91, 1, 7, 0, 4, 0, 0, 3, 0, 0, 0]))
        precondition(Switch2.memoryReadPayload(length: 4, address: 0x13000)
                     == Data([4, 0x7e, 0, 0, 0, 0x30, 1, 0]))
        precondition(Switch2.Model.nsoGameCube.hasAnalogTriggers)
        precondition(!Switch2.Model.nsoGameCube.hasHDRumble)
        precondition(Switch2.Model.proController2.hasHDRumble)
        precondition(!Switch2.Model.joyCon2Right.hasSecondStick)

        for length in 0..<60 {
            precondition(Switch2.InputReport(data: Data(repeating: 0, count: length)) == nil)
        }
        for value in UInt8.min...UInt8.max {
            var bytes = Data(repeating: 0, count: 63)
            bytes[4] = value
            bytes[60] = value
            bytes[61] = 255 - value
            let r = Switch2.InputReport(data: bytes)!
            precondition(r.buttons.rawValue == UInt32(value))
            precondition(r.leftTriggerRaw == value && r.rightTriggerRaw == 255 - value)
            // Nonzero Data.startIndex must not shift any protocol field.
            let sliced = (Data([0xaa]) + bytes).dropFirst()
            let s = Switch2.InputReport(data: sliced)!
            precondition(s.buttons == r.buttons && s.leftTriggerRaw == r.leftTriggerRaw)
        }
        let packed = Switch2.stickXY(Data([0xff, 0x0f, 0x80]), 0)
        precondition(packed.0 == 4095 && packed.1 == 2048)
        for model in Switch2.Model.allCases {
            var advert = Data(repeating: 0, count: 16)
            advert[3] = 0x7e; advert[4] = 0x05
            advert[5] = UInt8(model.rawValue & 0xff)
            advert[6] = UInt8(model.rawValue >> 8)
            let parsed = Switch2.parseAdvertisement(manufacturerData: advert)!
            precondition(parsed.model == model && parsed.isPairing)
            advert[10] = 1
            precondition(!Switch2.parseAdvertisement(manufacturerData: advert)!.isPairing)
        }
        precondition(Switch2.parseAdvertisement(manufacturerData: Data(repeating: 0, count: 15)) == nil)
        print("Protocol regression fixtures passed (all 256 trigger values, models and sliced data).")
    }
}
