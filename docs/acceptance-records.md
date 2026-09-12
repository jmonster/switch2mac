# Controller, discovery and energy acceptance records

For hash-matched local artifacts, recomputed CSV power means, and generated
compatibility matrices, use the [evidence-backed workflow](hardware-evidence.md).
The description-only schema below remains supported and is not silently promoted
to an evidence-backed hardware pass.

The validator records what a tester reports; it does not certify it independently
or manufacture measurements. It never launches a bridge, changes configuration,
collects logs, reads a controller or uploads data. Keep files local until reviewed.

```sh
python3 scripts/check-acceptance.py template > baseline.json
# Fill context and observed check/evidence fields; leave unperformed work not-run.
python3 scripts/check-acceptance.py check baseline.json
# Record the candidate separately, using the same build and controlled conditions.
python3 scripts/check-acceptance.py compare baseline.json candidate.json
```

The template is deliberately incomplete: no firmware, game, result, or power
reading is guessed. `check` distinguishes incomplete, reported failure, and
reported completion. Missing checks, unknown fields, duplicate JSON keys, invalid
models/architectures, non-finite numbers and oversized files are rejected. A
syntactically valid incomplete record may be stored but cannot support a power
comparison. This is a BLE qualification record, not USB acceptance.

Use the exact build revision from `--sensor-profile`. Record model ID, firmware,
macOS patch, architecture, output, game build and reproducible conditions. Test
the same physical unit for each pair. Conditions must specify the workload,
profile-relevant features, Mac power/display state, other processes, connection
count, radio environment, controller charge state and measurement instrument.
Evidence descriptions should identify a reviewed trace or test procedure, not
just say "works". Do not include credentials or unreviewed raw captures.

## Required behavior checks

New pairing, button wake, reconnect, sleep/wake, multiplayer, active input and
long held input must all have explicit pass/fail evidence before reported
completion. Do not silently skip another controller that loses input during a
reconnect. Test after a full idle timeout as well as during continuous reports.

Rumble, pointer, trigger travel and trigger clicks may be marked not-applicable
only with an explanation of the actual model/output/profile limitation. Missing
hardware or insufficient time means not-run, not not-applicable. Test separate
trigger clicks only where the output actually exposes them. A reduced profile
that omits the workload's required sensor is a failed choice for that workload.

## Discovery evaluation without speculative radio changes

Keep production discovery behavior unchanged while establishing a baseline.
For every model and firmware, test known-controller button wake, a new Sync-held
controller, four-player use, pairing while others are active, and wake after
Bluetooth off/on and Mac sleep. Record reconnect latency, failed attempts,
unintended connections and scan/CPU wakeup observations in evidence. Any future
scan-window or known-device retrieval change needs a separate reviewed revision
and the same tests; lower apparent wakeups do not justify missed button wakes.
These records validate acceptance evidence; they do not qualify a discovery policy.

## Power comparisons

For each profile record at least three equal-duration trials, including warmup
and steady-state rules in conditions. Each trial stores average `host_watts` and
`controller_watts` from independent measurements; use null for an unmeasured
metric. Never substitute controller voltage percentage, traffic count, CPU
percentage or host battery estimates for controller watts. Separate idle,
active-input, rumble and pointer workloads rather than averaging them together.

The comparator requires all behavior checks completed without failures, an
explicit compatibility baseline and reduced candidate, and identical declared
context including revision and trial durations. It reports mean/range and
arithmetic differences separately for each measured metric. Missing metrics stay
not-measured, and zero baseline power produces no percentage. It does not infer
battery lifetime, causal attribution, significance, or confidence intervals.

Repeat across model × firmware × OS × architecture × output/game combinations.
One passing record is not universal support. Publishing a release additionally
requires the separate signing, entitlement and installation gates. Automated
fixtures in `tests/acceptance` are labeled synthetic and are not acceptance data.
