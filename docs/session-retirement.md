# Session retirement and usable readiness

A controller session now has an explicit terminal state. Teardown marks it
ended before clearing pending notifications, callbacks, handshake steps and
timers. Late CoreBluetooth notifications, queued commands/rumble and audio
work cannot restart or emit input from that retired session. Essential
notification-state callbacks must actually report isNotifying. Completion
storage is cleared before invocation so a reentrant callback cannot erase new
work.

Readiness now requires both the existing handshake and a report accepted by
the existing decoder. No report lengths, controller bytes, pairing sequence,
GATT identifiers or connection timeouts are changed. The normal keep-alive
starts when the handshake completes even while awaiting input. If input
arrived during the handshake, its latest state is delivered when readiness is
announced. Readiness is announced once, before delivering the first usable
state, allowing the engine to attach output without losing that state.

Eleven production-session tests pass with fake CoreBluetooth boundaries. Five
new selected failure cases were first run against the prior PR #3 source and
failed: retired notifications, retired input/commands, false readiness,
disabled notifications, and reentrant completion. Additional tests check early
input and stopped keep-alives. The complete app is compiled separately with
Apple SDKs; these fixtures are synthetic, not controller captures.

Run bash tests/session/run.sh. Physical pairing/reconnect and keep-alive
behavior still need acceptance on the target firmware. Engine-level slot
replacement and delayed player-number callbacks remain separate ownership
boundaries; this session-local guard is not a claim that every lifecycle race
in the application has been eliminated.
