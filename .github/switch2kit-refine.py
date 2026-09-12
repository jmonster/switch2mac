"""One-time reviewed edits, confined by the workflow to the extraction branch."""
from pathlib import Path
import re
root = Path('.')
for name in ['ControllerSession', 'ControllerTransport']:
    p = root / f'Sources/Switch2Kit/Bluetooth/{name}.swift'
    s = p.read_text()
    s = re.sub(r'^(    )func (peripheral(?:\(|IsReady)|centralManager(?:\(|DidUpdateState))', r'\1package func \2', s, flags=re.M)
    if name == 'ControllerTransport':
        s = s.replace('        guard !disconnecting.contains(peripheral.identifier), running, !suspended,', '        guard central === self.central else { return }\n        guard !disconnecting.contains(peripheral.identifier), running, !suspended,')
        s = s.replace('                        rssi RSSI: NSNumber) {\n', '                        rssi RSSI: NSNumber) {\n        guard central === self.central else { return }\n')
        s = s.replace('                        error: Error?) {\n', '                        error: Error?) {\n        guard central === self.central else { return }\n')
    p.write_text(s)
p = root / 'Sources/Switch2Kit/Public/Lifecycle.swift'
s = p.read_text()
for name in ['discoveryMode', 'rememberedControllers', 'maximumControllers', 'includeSerialNumbers']:
    s = s.replace('    public var ' + name + ':', '    public let ' + name + ':')
old = '        self.discoveryMode = discoveryMode; self.rememberedControllers = rememberedControllers\n        self.maximumControllers = min(64, max(1, maximumControllers)); self.includeSerialNumbers = includeSerialNumbers'
assert old in s
s = s.replace(old, '''        self.discoveryMode = discoveryMode
        self.maximumControllers = min(64, max(1, maximumControllers))
        self.includeSerialNumbers = includeSerialNumbers
        var unique: [Switch2ControllerID] = []
        for id in rememberedControllers where !unique.contains(id) {
            unique.append(id)
            if unique.count == self.maximumControllers { break }
        }
        self.rememberedControllers = unique''')
p.write_text(s)
p = root / 'Sources/Switch2Kit/Public/ControllerTypes.swift'
s = p.read_text()
s = s.replace('    package let sessionGeneration: UUID', '    /// Transient token for this connection. Changes on reconnect; not a persistent device identity.\n    public var connectionID: UUID { sessionGeneration }\n    package let sessionGeneration: UUID')
s = s.replace('    public let receivedAt: TimeInterval\n', '    public let receivedAt: TimeInterval\n    /// Per-connection report sequence starting at one. Gaps reveal dropped input; fixtures may use zero.\n    public let sequence: UInt64\n')
s = s.replace('                receivedAt: TimeInterval = 0) {', '                receivedAt: TimeInterval = 0, sequence: UInt64 = 0) {')
s = s.replace('self.motion = motion; self.optical = optical; self.receivedAt = receivedAt', 'self.motion = motion; self.optical = optical; self.receivedAt = receivedAt; self.sequence = sequence')
p.write_text(s)
p = root / 'Sources/Switch2Kit/Protocol/DecodedState.swift'
s = p.read_text().replace('sensorProfile: Switch2.Feature.SensorProfile = .compatibility) -> Switch2ControllerState {', 'sensorProfile: Switch2.Feature.SensorProfile = .compatibility,\n                          sequence: UInt64 = 0) -> Switch2ControllerState {').replace('receivedAt: receivedAt)', 'receivedAt: receivedAt, sequence: sequence)')
p.write_text(s)
p = root / 'Sources/Switch2Kit/Bluetooth/ControllerTransport.swift'
p.write_text(p.read_text().replace('sensorProfile: session.sensorProfile),', 'sensorProfile: session.sensorProfile, sequence: session.reportCount),'))
p = root / 'Sources/Switch2Kit/Public/Observation.swift'
s = p.read_text()
s = s.replace('    package let lifetime: SessionLifetime?\n', '    package let lifetime: SessionLifetime?\n    // Only snapshots carry this bounded ready-set token list. No session objects escape.\n    package var snapshotLifetimes: [SessionLifetime] = []\n')
old = '''            // State snapshots are authoritative at delivery time, never historical ready sets.
            switch envelope.event {
            case .snapshot, .status: envelope = current()
            default: break
            }
'''
assert old in s
s = s.replace(old, '''            // Preserve FIFO delivery at full rate. Refresh a historical snapshot only
            // when one of its attempts retired; refreshing every status used to jump
            // the sequence watermark over valid queued input even without overflow.
            if envelope.snapshotLifetimes.contains(where: { !$0.isActive }) { envelope = current() }
''')
s = s.replace('        var observers: [UInt64: EventMailbox] = [:]\n', '        var observers: [UInt64: EventMailbox] = [:]\n        var lifetimes: [Switch2ControllerID: SessionLifetime] = [:]\n')
s = s.replace('EventEnvelope(sequence: $0.sequence, event: .snapshot($0.snapshot), lifetime: nil)', 'EventEnvelope(sequence: $0.sequence, event: .snapshot($0.snapshot), lifetime: nil,\n                                         snapshotLifetimes: Array($0.lifetimes.values))')
s = s.replace('EventEnvelope(sequence: value.sequence, event: .snapshot(value.snapshot), lifetime: nil)', 'EventEnvelope(sequence: value.sequence, event: .snapshot(value.snapshot), lifetime: nil,\n                                          snapshotLifetimes: Array(value.lifetimes.values))')
old = '''            value.snapshot = snapshot; value.sequence &+= 1
            let envelope = EventEnvelope(sequence: value.sequence, event: event, lifetime: lifetime)
'''
assert old in s
s = s.replace(old, '''            value.snapshot = snapshot; value.sequence &+= 1
            if let lifetime {
                switch event {
                case .connected(let controller), .input(let controller): value.lifetimes[controller.id] = lifetime
                default: break
                }
            }
            let readyIDs = Set(snapshot.controllers.map(\.id))
            value.lifetimes = value.lifetimes.filter { readyIDs.contains($0.key) }
            var envelope = EventEnvelope(sequence: value.sequence, event: event, lifetime: lifetime)
            switch event {
            case .snapshot, .status: envelope.snapshotLifetimes = Array(value.lifetimes.values)
            default: break
            }
''')
s = s.replace('            value.observers.removeAll()\n', '            value.observers.removeAll()\n            value.lifetimes.removeAll()\n')
p.write_text(s)
p = root / 'Sources/FinallyTheControllerWorks/Runtime/Switch2KitAdapter.swift'
s = p.read_text()
start = s.index('enum Switch2KitStateAdapter')
end = s.index('{', start) + 1
depth = 1
while depth:
    depth += (s[end] == '{') - (s[end] == '}')
    end += 1
(root / 'Sources/FinallyTheControllerWorks/Runtime/Switch2KitStateAdapter.swift').write_text('import Switch2Kit\n\n// Application-owned conversion; no protocol decoding or transport ownership.\n' + s[start:end] + '\n')
p.write_text(s[:start] + s[end:])
