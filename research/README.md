# Research

Protocol documentation and reverse-engineering write-ups produced while
building Finally the Controller Works. Published so the next person
doesn't have to rediscover any of it.

| Document | What it covers |
|---|---|
| [PROTOCOL.md](PROTOCOL.md) | The practical reference: discovery, GATT layout, command protocol, handshake, input reports, calibration, rumble, LEDs, app-layer bonding, macOS keep-alive quirk, and headset audio (§10) |
| [audio-investigation.md](audio-investigation.md) | The ongoing hunt for controller audio over BLE: lanes, the "haptic feedback bug" post-mortem, mic-lane findings, the USB shortcut, open questions |
| [capture-format-analysis.md](capture-format-analysis.md) | Deep study of one 30 s mic-lane capture: full packet anatomy, the motion-telemetry blob decode, and the formal codec rule-outs (Opus, LC3, ADPCM×3, PCM) |

Everything here was observed on real hardware (Pro Controller 2,
firmware 2.0+, macOS host) unless explicitly marked as inference.
Community groundwork is credited inline — especially
[ndeadly/switch2_controller_research](https://github.com/ndeadly/switch2_controller_research).

Corrections welcome: if you have captures or hardware that contradicts
anything here, please open an issue.
