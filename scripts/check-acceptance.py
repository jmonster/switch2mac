#!/usr/bin/env python3
"""Validate local, explicitly recorded controller/energy acceptance evidence.

This tool never contacts hardware, runs a bridge, collects logs or uploads data.
It validates reported evidence; it does not independently certify measurements.
"""
import argparse
import json
import math
from pathlib import Path
import statistics

MAX_BYTES = 65_536
PROFILES = ('compatibility', 'gamepad', 'motion', 'pointer')
CONTEXT = ('revision', 'model', 'firmware', 'macos', 'architecture', 'output', 'game_build', 'conditions')
CHECKS = ('new_pairing', 'button_wake', 'reconnect', 'sleep_wake', 'multiplayer',
          'active_input', 'held_input', 'rumble', 'pointer', 'trigger_travel', 'trigger_clicks')
OPTIONAL = {'rumble', 'pointer', 'trigger_travel', 'trigger_clicks'}
METRICS = ('host_watts', 'controller_watts')


class Invalid(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Invalid(message)


def template():
    return {'schema': 1, 'profile': 'compatibility', 'transport': 'ble',
            'context': dict.fromkeys(CONTEXT),
            'checks': {key: {'result': 'not-run', 'evidence': ''} for key in CHECKS},
            'trials': []}


def validate(record):
    require(isinstance(record, dict) and set(record) == set(template()), 'Unexpected record fields')
    require(type(record['schema']) is int and record['schema'] == 1, 'Unknown schema')
    require(record['profile'] in PROFILES and record['transport'] == 'ble', 'Unknown BLE profile/transport')
    context = record['context']
    require(isinstance(context, dict) and set(context) == set(CONTEXT), 'Missing/unknown context field')
    missing = []
    for key, value in context.items():
        require(value is None or (isinstance(value, str) and 0 < len(value.strip()) <= 2000), 'Invalid context: ' + key)
        if value is None:
            missing.append(key)
    revision = context['revision']
    require(revision is None or (len(revision) == 40 and all(c in '0123456789abcdef' for c in revision)), 'Invalid source revision')
    require(context['model'] in (None, '2066', '2067', '2069', '2073'), 'Unknown controller model')
    require(context['architecture'] in (None, 'arm64', 'x86_64'), 'Unknown architecture')
    require(context['output'] in (None, 'sdl', 'browser', 'retroarch', 'hid'), 'Unknown output')
    checks = record['checks']
    require(isinstance(checks, dict) and set(checks) == set(CHECKS), 'Missing/unknown acceptance check')
    failures = []
    for key, check in checks.items():
        require(isinstance(check, dict) and set(check) == {'result', 'evidence'}, 'Invalid check: ' + key)
        result, evidence = check['result'], check['evidence']
        require(result in ('not-run', 'pass', 'fail', 'not-applicable'), 'Unknown check result')
        require(isinstance(evidence, str) and len(evidence) <= 2000, 'Invalid evidence')
        require(result == 'not-run' or bool(evidence.strip()), 'Completed checks need an evidence description')
        require(result != 'not-applicable' or key in OPTIONAL, 'Core connection/input checks cannot be skipped')
        if result == 'not-run':
            missing.append(key)
        if result == 'fail':
            failures.append(key)
    trials = record['trials']
    require(isinstance(trials, list) and len(trials) <= 100, 'At most 100 trials are accepted')
    for trial in trials:
        require(isinstance(trial, dict) and set(trial) == {'duration_seconds', *METRICS}, 'Unknown measurement fields/units')
        for key, value in trial.items():
            require((key in METRICS and value is None) or
                    (type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 1_000_000), 'Invalid finite measurement')
        require(trial['duration_seconds'] > 0, 'Trial duration must be positive')
    status = 'reported-failure' if failures else ('incomplete' if missing else 'reported-complete')
    return {'status': status, 'missing': missing, 'failed': failures, 'trials': len(trials),
            'independently_verified': False, 'energy_measured': bool(trials) and
            any(all(t[key] is not None for t in trials) for key in METRICS)}


def compare(baseline, candidate):
    for record in (baseline, candidate):
        require(validate(record)['status'] == 'reported-complete', 'Incomplete/failed acceptance cannot support a power comparison')
        require(len(record['trials']) >= 3, 'Record at least three trials per profile')
    require(baseline['profile'] == 'compatibility' and candidate['profile'] != 'compatibility', 'Compare compatibility against a reduced profile')
    require(baseline['context'] == candidate['context'], 'Revision, hardware/firmware, game, OS and controlled conditions must match')
    durations = [t['duration_seconds'] for record in (baseline, candidate) for t in record['trials']]
    require(len(set(durations)) == 1, 'Use equal trial durations for this comparison')
    metrics = {}
    for key in METRICS:
        a, b = ([t[key] for t in record['trials']] for record in (baseline, candidate))
        if any(v is None for v in a + b):
            metrics[key] = {'status': 'not-measured'}
            continue
        before, after = statistics.fmean(a), statistics.fmean(b)
        metrics[key] = {'baseline_mean': before, 'candidate_mean': after,
                        'delta_watts': after - before,
                        'reduction_percent': (before - after) / before * 100 if before > 0 else None,
                        'baseline_range': [min(a), max(a)], 'candidate_range': [min(b), max(b)]}
    return {'profile': candidate['profile'], 'metrics': metrics, 'independently_verified': False,
            'scope': 'Descriptive comparison of user-recorded mean power; not battery life or causal/statistical certification.'}


def load(path):
    with Path(path).open('rb') as stream:
        data = stream.read(MAX_BYTES + 1)
    require(len(data) <= MAX_BYTES, 'Evidence record exceeds 64 KiB')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate JSON field: ' + key)
            result[key] = value
        return result
    def reject_constant(value):
        raise Invalid('Non-finite JSON number: ' + value)
    return json.loads(data, object_pairs_hook=unique, parse_constant=reject_constant)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('template')
    commands.add_parser('check').add_argument('record')
    pair = commands.add_parser('compare'); pair.add_argument('baseline'); pair.add_argument('candidate')
    args = parser.parse_args()
    try:
        result = template() if args.command == 'template' else (
            validate(load(args.record)) if args.command == 'check' else compare(load(args.baseline), load(args.candidate)))
        print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))
    except (OSError, ValueError, TypeError) as error:
        parser.exit(2, 'Invalid acceptance evidence: ' + str(error) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
