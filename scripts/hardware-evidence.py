#!/usr/bin/env python3
"""Check local evidence and measured power; never collect or certify hardware data.

The schema-1 acceptance tool remains available for description-only records.
This envelope requires hash-matched local artifacts for observed pass/fail results
and recomputes every reported power mean from a bounded, explicitly named CSV.
"""
import argparse
import csv
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import runpy
import stat
import statistics

acceptance = runpy.run_path(str(Path(__file__).with_name('check-acceptance.py')))
Invalid = acceptance['Invalid']
require = acceptance['require']
METRICS = acceptance['METRICS']
MAX_RECORD = 65_536
MAX_ARTIFACT = 2_097_152
MAX_TOTAL = 33_554_432
KINDS = ('hardware', 'simulation', 'runtime')
MODES = ('automatic', 'quiet-when-ready')


def decode(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate JSON field')
            result[key] = value
        return result
    def finite(value):
        raise Invalid('Non-finite JSON number')
    return json.loads(data, object_pairs_hook=unique, parse_constant=finite)


class EvidenceRoot:
    """Pin the chosen root. Descendant symlinks and special files are refused.

    Each distinct file is read once into a bounded snapshot for one command.
    A trusted local filesystem is required; this is not a same-user sandbox.
    """
    def __init__(self, root):
        self.fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        self.total = 0
        self.cache = {}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        os.close(self.fd)

    def read(self, path, limit=MAX_ARTIFACT):
        require(isinstance(path, str) and len(path) <= 1024, 'Invalid relative evidence path')
        parts = path.split('/')
        require(1 <= len(parts) <= 16 and all(
            p not in ('.', '..') and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._ -]{0,127}', p)
            for p in parts), 'Use a relative path without traversal or ambiguous components')
        if path in self.cache:
            data = self.cache[path]
            require(len(data) <= limit, 'File exceeds its size limit')
            return data
        directory = os.dup(self.fd)
        try:
            for part in parts[:-1]:
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                  dir_fd=directory)
                os.close(directory)
                directory = next_fd
            fd = os.open(parts[-1], os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                         dir_fd=directory)
            try:
                before = os.fstat(fd)
                require(stat.S_ISREG(before.st_mode), 'Evidence must be a regular file')
                require(before.st_size <= limit and self.total + before.st_size <= MAX_TOTAL,
                        'Evidence exceeds the file or aggregate size limit')
                chunks, length = [], 0
                while True:
                    chunk = os.read(fd, min(65_536, limit + 1 - length))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    length += len(chunk)
                    require(length <= limit and self.total + length <= MAX_TOTAL, 'Evidence grew beyond the limit')
                after = os.fstat(fd)
                require((before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                        (after.st_size, after.st_mtime_ns, after.st_ctime_ns) and length == after.st_size,
                        'Evidence changed while reading')
                data = b''.join(chunks)
            finally:
                os.close(fd)
        finally:
            os.close(directory)
        self.total += len(data)
        self.cache[path] = data
        return data

    def artifact(self, reference):
        require(isinstance(reference, dict) and set(reference) == {'path', 'sha256'}, 'Invalid artifact reference')
        digest = reference['sha256']
        require(isinstance(digest, str) and re.fullmatch(r'[0-9a-f]{64}', digest), 'Invalid artifact SHA-256')
        data = self.read(reference['path'])
        require(hashlib.sha256(data).hexdigest() == digest, 'Artifact hash mismatch')
        return data


def power(data):
    """Time-weighted, piecewise-linear mean; not an inferred battery lifetime."""
    require(len(data) <= MAX_ARTIFACT, 'Power trace exceeds limit')
    rows = csv.reader(io.StringIO(data.decode('utf-8')), strict=True)
    require(next(rows, None) == ['time_seconds', 'power_watts'], 'CSV must declare time_seconds,power_watts')
    samples = []
    for row in rows:
        require(len(samples) < 100_000 and len(row) == 2, 'Invalid sample row or sample count')
        require(all(len(value) <= 64 for value in row), 'Numeric sample exceeds limit')
        t, watts = map(float, row)
        require(math.isfinite(t) and 0 <= t <= 1_000_000_000_000 and math.isfinite(watts) and 0 <= watts <= 10_000,
                'Invalid finite sample or units')
        require(not samples or t > samples[-1][0], 'Sample timestamps must strictly increase')
        samples.append((t, watts))
    require(len(samples) >= 2, 'At least two timestamped samples are required')
    duration = samples[-1][0] - samples[0][0]
    require(0 < duration <= 86_400, 'Invalid trace duration')
    energy = math.fsum((b[0] - a[0]) * (a[1] + b[1]) / 2 for a, b in zip(samples, samples[1:]))
    return {'duration_seconds': duration, 'mean_watts': energy / duration,
            'sample_count': len(samples), 'max_gap_seconds': max(b[0] - a[0] for a, b in zip(samples, samples[1:])),
            'method': 'trapezoidal; assumes linear power between samples'}


def template(kind='hardware'):
    return {'schema': 1, 'kind': kind, 'discovery_mode': 'automatic',
            'record': acceptance['template'](),
            'evidence': {key: [] for key in acceptance['CHECKS']}, 'power_traces': []}


def validate(envelope, root):
    require(isinstance(envelope, dict) and set(envelope) == set(template()), 'Unexpected envelope fields')
    require(type(envelope['schema']) is int and envelope['schema'] == 1, 'Unknown envelope schema')
    require(envelope['kind'] in KINDS and envelope['discovery_mode'] in MODES, 'Unknown evidence kind or discovery mode')
    record = envelope['record']
    result = acceptance['validate'](record)
    refs = envelope['evidence']
    require(isinstance(refs, dict) and set(refs) == set(acceptance['CHECKS']), 'Missing or unknown check evidence')
    for key, check in record['checks'].items():
        artifacts = refs[key]
        require(isinstance(artifacts, list) and len(artifacts) <= 8, 'At most eight artifacts per check')
        require(check['result'] not in ('pass', 'fail') or artifacts, 'Observed pass/fail requires a local artifact')
        require(check['result'] != 'not-run' or not artifacts, 'Unperformed checks cannot carry observation artifacts')
        for artifact in artifacts:
            require(root.artifact(artifact), 'Observation artifact must not be empty')
    traces = envelope['power_traces']
    require(isinstance(traces, list) and len(traces) == len(record['trials']), 'Every trial needs matching trace slots')
    seen = {key: set() for key in METRICS}
    for trial, trace in zip(record['trials'], traces):
        require(isinstance(trace, dict) and set(trace) == set(METRICS), 'Unknown trace metric or units')
        for key in METRICS:
            value, reference = trial[key], trace[key]
            if value is None:
                require(reference is None, 'Unmeasured power cannot have a measured trace')
                continue
            data = root.artifact(reference)
            summary = power(data)
            require(math.isclose(summary['duration_seconds'], trial['duration_seconds'], rel_tol=0, abs_tol=1e-6),
                    'Reported duration does not match the measured trace')
            require(math.isclose(summary['mean_watts'], value, rel_tol=1e-9, abs_tol=1e-9),
                    'Reported mean does not match time-weighted trace power')
            require(reference['sha256'] not in seen[key], 'Reusing one trace is not an independent trial')
            seen[key].add(reference['sha256'])
    result = dict(result, evidence_kind=envelope['kind'], artifact_count=len(root.cache),
                  eligible_hardware_pass=envelope['kind'] == 'hardware' and result['status'] == 'reported-complete')
    result['scope'] = 'Hash-consistent tester observations, not independent hardware certification.'
    return result


def load(path, root):
    return decode(root.read(path, MAX_RECORD))


def compare(baseline, candidate, root):
    for record in (baseline, candidate):
        require(validate(record, root)['eligible_hardware_pass'], 'Only complete, passing hardware observations may be compared')
        require(len(record['record']['trials']) >= 3, 'At least three distinct traces per setting are required')
    a, b = baseline['record'], candidate['record']
    require(a['context'] == b['context'], 'Build, physical unit/conditions, firmware, OS and game context must match')
    factors = []
    if a['profile'] != b['profile']:
        require(a['profile'] == 'compatibility', 'Sensor baseline must use compatibility')
        factors.append('sensor_profile')
    if baseline['discovery_mode'] != candidate['discovery_mode']:
        require(baseline['discovery_mode'] == 'automatic', 'Discovery baseline must use automatic scanning')
        factors.append('discovery_mode')
    require(len(factors) == 1, 'Change exactly one setting between baseline and candidate')
    require(len({t['duration_seconds'] for r in (a, b) for t in r['trials']}) == 1, 'Use equal trial durations')
    metrics = {}
    for key in METRICS:
        before, after = ([t[key] for t in r['trials']] for r in (a, b))
        if any(v is None for v in before + after):
            metrics[key] = {'status': 'not-measured'}
            continue
        hashes = [{t[key]['sha256'] for t in r['power_traces']} for r in (baseline, candidate)]
        require(not hashes[0].intersection(hashes[1]), 'Baseline and candidate cannot reuse a trace')
        mean_a, mean_b = statistics.fmean(before), statistics.fmean(after)
        metrics[key] = {'baseline_mean_watts': mean_a, 'candidate_mean_watts': mean_b,
                        'delta_watts': mean_b - mean_a,
                        'reduction_percent': (mean_a - mean_b) / mean_a * 100 if mean_a else None,
                        'baseline_range': [min(before), max(before)], 'candidate_range': [min(after), max(after)]}
    return {'changed_factor': factors[0], 'metrics': metrics, 'independently_verified': False,
            'scope': 'Descriptive trace-backed comparison, not causality, significance or battery-life certification.'}


def matrix(paths, root):
    require(len(paths) <= 256, 'At most 256 records per matrix')
    rows = []
    for path in paths:
        entry = load(path, root)
        status = validate(entry, root)
        context = entry['record']['context']
        rows.append({**{k: context[k] for k in ('revision', 'model', 'firmware', 'macos', 'architecture', 'output', 'game_build')},
                     'profile': entry['record']['profile'], 'discovery_mode': entry['discovery_mode'],
                     'evidence_kind': entry['kind'], 'status': status['status'],
                     'eligible_hardware_pass': status['eligible_hardware_pass'],
                     'record_sha256': hashlib.sha256(root.read(path, MAX_RECORD)).hexdigest()})
    return {'schema': 1, 'rows': rows, 'scope': 'No record or CI result implies unobserved hardware support.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default='.', help='Explicit local evidence directory; paths below it must be relative')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('template').add_argument('--kind', choices=KINDS, default='hardware')
    commands.add_parser('check').add_argument('record')
    commands.add_parser('trace').add_argument('path')
    pair = commands.add_parser('compare'); pair.add_argument('baseline'); pair.add_argument('candidate')
    commands.add_parser('matrix').add_argument('records', nargs='*')
    args = parser.parse_args()
    try:
        if args.command == 'template':
            result = template(args.kind)
        else:
            with EvidenceRoot(args.root) as root:
                if args.command == 'check':
                    result = validate(load(args.record, root), root)
                elif args.command == 'compare':
                    result = compare(load(args.baseline, root), load(args.candidate, root), root)
                elif args.command == 'matrix':
                    result = matrix(args.records, root)
                else:
                    data = root.read(args.path)
                    result = dict(power(data), reference={'path': args.path, 'sha256': hashlib.sha256(data).hexdigest()})
        print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))
    except (OSError, ValueError, TypeError, RecursionError, csv.Error) as error:
        parser.exit(2, 'Invalid hardware evidence: ' + str(error) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
