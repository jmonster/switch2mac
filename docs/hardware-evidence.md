# Hardware evidence and reproducible power comparisons

`check-acceptance.py` keeps its description-only schema and behavior. The new
`hardware-evidence.py` adds an evidence envelope around that record. Neither tool
collects data, runs Bluetooth, changes settings, uploads files, or independently
certifies what a tester says happened. Hardware, simulation and packaged-runtime
records remain distinct. The checked-in [matrix](hardware-matrix.json) initially
contains **no physical observations**, rather than invented passes.

## Record one actual observation

From the repository root:

```sh
mkdir -p qualification
python3 scripts/hardware-evidence.py template > qualification/controller.json
python3 scripts/hardware-evidence.py --root qualification check controller.json
```

An untouched template is valid but incomplete. Fill `record.context` with the
actual source revision, controller model/firmware, macOS patch, architecture,
output and game build. Include an anonymous label for the physical unit, workload,
instrument, calibration, power/display state, warmup, radio conditions and test
procedure in `conditions`. Compare the same physical unit and build. Do not use
serial numbers, credentials or unreviewed raw input/audio in public evidence.

`record.checks` holds the original result and explanation for each behavior.
For every observed `pass` or `fail`, `evidence[check]` must name at least one
nonempty local artifact as `{"path":"observations/reconnect.txt","sha256":"..."}`.
Use the actual SHA-256 of the reviewed file (for example `shasum -a 256 FILE`).
Paths are relative to the explicit evidence root; never use absolute paths or
`..`. Unperformed checks stay `not-run` with no artifacts. Core connection/input
checks cannot be marked not-applicable. Optional checks need an explanation of
the actual model/output/profile limit, not missing equipment or time.

Artifact presence and matching hashes prove byte consistency, not that a video
or note accurately represents hardware behavior. A forged note can still be a
hash-consistent note. Reviewers must inspect evidence before endorsing a claim.
Simulation and runtime records are never eligible for a hardware pass, even when
every reported behavior is marked pass. The tool outputs no global certification.

## Import and verify instrumented power

Export each independent trial as UTF-8 CSV with exactly these two column names:

```text
time_seconds,power_watts
```

Preserve real increasing timestamps and watt readings. Relative or absolute
seconds are accepted; convert instrument units explicitly, never relabel CPU
percent, battery voltage, traffic count or sample index as watts or seconds.
Host and controller readings use separate files and remain separate metrics.

```sh
python3 scripts/hardware-evidence.py --root qualification trace traces/host-1.csv
```

The result includes its hash reference, duration, sample count, largest sampling
gap and a time-weighted mean, calculated by trapezoidal integration. The method
assumes linear power between samples; it cannot reconstruct unobserved bursts.
Review gaps and instrument resolution. Copy the mean/duration into the matching
`record.trials` entry, and the returned reference into `power_traces` at the same
index, under `host_watts` or `controller_watts`. An unmeasured metric must be null
in both places. Validation re-reads the hash-matched trace and recomputes the
mean/duration; unsupported manually entered averages fail validation.

```sh
python3 scripts/hardware-evidence.py --root qualification check baseline.json
python3 scripts/hardware-evidence.py --root qualification compare baseline.json candidate.json
```

Comparison requires complete passing hardware observations, identical declared
context, at least three distinct equal-duration traces per setting, and exactly
one changed factor: compatibility versus a reduced sensor profile, or automatic
versus quiet-when-ready discovery. Reused trace bytes cannot count as independent
trials or be shared across baseline/candidate. Preserve capture timestamps so
independent flat readings are still distinguishable; do not fabricate differences.
Missing metrics stay not-measured, and a zero baseline has no percentage result.
Reported differences are descriptive, not causal inference, confidence intervals,
battery-life estimates or evidence that an omitted feature was unnecessary.

## Generate a compatibility matrix

```sh
python3 scripts/hardware-evidence.py --root qualification matrix controller.json other.json
```

JSON rows retain each record's kind, incomplete/failure/completion status, source,
model, firmware, OS, architecture, output/game, profile/discovery mode and record
hash. One failed/incomplete observation is not overwritten by another passing
one. Conditions and artifact paths are deliberately not copied into matrix rows.
Zero input records produces an empty matrix. The CLI writes only to stdout;
explicitly redirect output after reviewing the records. No publishing is automatic.

## Input limits and tests

Records are capped at 64 KiB; artifacts at 2 MiB each; a command's distinct-file
snapshot at 32 MiB. The maximums are 256 matrix records, 100 trials per record,
eight artifacts per behavior check, 100,000 samples per CSV, and 24-hour traces.
Malformed/non-finite numbers, duplicate JSON keys, bad units, non-increasing
samples, missing artifacts, hash mismatches and edited means fail cleanly.

The root directory is pinned once. Every descendant is opened descriptor-relative
without following symlinks; special files, including pipes, are rejected before
reading. Read-size and file-change checks bound and snapshot the data. Use a
trusted local filesystem: this is not protection from hostile software running
as the same user, signatures of observations, encryption, or secure deletion.

`tests/hardware-evidence` uses only labeled synthetic fixtures in temporary
directories. Tests cover negative claims, trace arithmetic, incomplete matrices,
malformed input, traversal/symlinks/pipes, size limits, changing files and matched
comparisons. CI results from these tests are not inserted into the hardware matrix.

Implementation references: Python's descriptor-relative `os.open`/`os.stat`
interfaces and the existing [acceptance procedure](acceptance-records.md). Radio
scheduling guidance motivates measurement, not an assumed battery-life gain:
[Apple's Bluetooth energy guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/BluetoothBestPractices.html).
