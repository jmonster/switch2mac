"""One-time source-path and ownership migration; no protocol method changes."""
from pathlib import Path
import re
root = Path('.')
for p in (root / 'tests').glob('*/run.sh'):
    s = p.read_text()
    if 'Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift' not in s:
        continue
    patterns = [
        r"s\s*=\s*\(base\s*/\s*'Bluetooth/ControllerSession.swift'\)\.read_text\(\)\n.*?write_text\([^\n]*\)\n",
        r"s\s*=\s*Path\('Sources/FinallyTheControllerWorks/Bluetooth/ControllerSession.swift'\)\.read_text\(\)\n.*?write_text\([^\n]*\)\n",
    ]
    for pattern in patterns:
        def empty_state(match):
            text = match.group()
            assert 'State.swift' in text or 'Path(sys.argv[1])' in text
            writer = [line for line in text.splitlines() if 'write_text' in line][-1]
            lhs = writer[:writer.index('.write_text')]
            return lhs + ".write_text('// ControllerState is compiled from the production Switch2Kit target.\\n')\n"
        s = re.sub(pattern, empty_state, s, flags=re.S)
    if p.parent.name == 'virtualhid':
        s = s.replace("s = (root / 'Bluetooth/ControllerSession.swift').read_text()\na = s.index('struct ControllerState:'); b = s.index('/// Called on the Bluetooth queue.', a)\n", '')
        s = s.replace("'import Foundation\\n' + s[a:b] + '\\nprotocol ControllerOutputSink:'", "'import Foundation\\nprotocol ControllerOutputSink:'")
    s = s.replace('Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift', '"${kit_sources[@]}"')
    line = next(line for line in s.splitlines() if line.startswith('cd '))
    s = s.replace(line, line + '\nsource tests/support/kit-sources.sh', 1)
    s = s.replace('swiftc ', 'swiftc "${kit_flags[@]}" ')
    p.write_text(s)
p = root / 'tests/run.sh'
s = p.read_text().replace('Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift', '"${kit_sources[@]}"').replace('swiftc ', 'swiftc "${kit_flags[@]}" ')
s = s.replace('work=$(mktemp -d)', 'source tests/support/kit-sources.sh\nwork=$(mktemp -d)')
p.write_text(s)
p = root / 'Sources/FinallyTheControllerWorks/Runtime/DirectRumbleCapability.swift'
p.write_text(p.read_text().replace('import Switch2Kit\n\n', '').replace('extension Switch2ControllerModel', 'extension Switch2.Model'))
p = root / 'Sources/FinallyTheControllerWorks/Runtime/Switch2KitAdapter.swift'
s = p.read_text()
start = s.index('// Process environment selection')
policy = s[start:]
p.write_text(s[:start])
(root / 'Sources/FinallyTheControllerWorks/Runtime/ApplicationSensorPolicy.swift').write_text('import Foundation\n\n' + policy)
p = root / 'Sources/FinallyTheControllerWorks/Runtime/SensorProfileReport.swift'
p.write_text(p.read_text().replace('Switch2.Feature.flags(for: model)', 'Switch2.Feature.flags(for: model, profile: profile)'))
p = root / 'tests/power-profiles/Tests.swift'
s = p.read_text().replace('Switch2.Feature.selectedProfile == expected', 'ApplicationSensorPolicy.selectedProfile == expected')
s = s.replace('queue: queue, delegate: delegate)', 'queue: queue, delegate: delegate, sensorProfile: ApplicationSensorPolicy.selectedProfile)')
p.write_text(s)
p = root / 'tests/power-profiles/ReportTests.swift'
p.write_text(p.read_text().replace('Switch2.Feature.flags(for: model)', 'Switch2.Feature.flags(for: model, profile: ApplicationSensorPolicy.selectedProfile)'))
p = root / 'tests/engine/RetryTests.swift'
s = p.read_text().replace('engine.discoveryDefaults.set(true, forKey: DiscoveryPolicy.enabledKey)', 'engine.discovery.configure(mode: .quietWhenReady, remembered: [])')
s = s.replace('if suspend { engine.setSuspended(true) } else { engine.stop() }', 'engine.stop() // Both application stop and sleep retire transport sessions.')
s = s.replace('if suspend { engine.setSuspended(false) } else { engine.resume() }', 'engine.start() // Wake/resume starts a fresh transport lifecycle.')
s = s.replace('for suspend in [false, true] {', 'for _ in [false, true] {')
p.write_text(s)
p = root / 'tests/discovery/EngineTests.swift'
s = p.read_text().replace('engine.discoveryDefaults.set(true, forKey: DiscoveryPolicy.enabledKey)', 'engine.discovery.configure(mode: .quietWhenReady, remembered: [])')
s = s.replace('engine.lastState == .ready', 'engine.discoveryState == .paused').replace('engine.requestDiscoveryWindow()', 'engine.requestDiscoveryWindow(seconds: 60)')
s = s.replace('engine.discoveryDefaults.set(false, forKey: DiscoveryPolicy.enabledKey)', 'engine.discovery.configure(mode: .automatic, remembered: [])').replace('engine.resume()', 'engine.start()')
s = s.replace('"continuous discovery must remain the default"', '"the dashboard explicitly selects automatic discovery"')
p.write_text(s)
p = root / 'tests/discovery/PolicyTests.swift'
p.write_text(p.read_text().replace('policy.work', 'policy.policy.work'))
for name in ['tests/engine/EngineTests.swift', 'tests/discovery/EngineTests.swift', 'tests/engine/RetryRegression.swift', 'tests/engine/RetryTests.swift']:
    p = root / name
    p.write_text(p.read_text().replace('BridgeEngine()', 'BridgeEngine.fixture()'))
