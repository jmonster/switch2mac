import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('acceptance', 'scripts/check-acceptance.py')
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)


def fixture(profile='compatibility', power=10):
    record = a.template(); record['profile'] = profile
    record['context'] = dict(revision='a'*40, model='2069', firmware='synthetic-test', macos='26.0',
                             architecture='arm64', output='sdl', game_build='fixture-only', conditions='not real measurements')
    for check in record['checks'].values():
        check.update(result='pass', evidence='synthetic fixture; not hardware acceptance')
    record['trials'] = [dict(duration_seconds=60, host_watts=power, controller_watts=None) for _ in range(3)]
    return record


class Tests(unittest.TestCase):
    def test_template_does_not_claim_evidence(self):
        result = a.validate(a.template())
        self.assertEqual(result['status'], 'incomplete')
        self.assertFalse(result['independently_verified']); self.assertFalse(result['energy_measured'])
        with self.assertRaises(a.Invalid): a.compare(a.template(), a.template())

    def test_separate_metrics_and_descriptive_arithmetic(self):
        result = a.compare(fixture(), fixture('gamepad', 8))
        self.assertEqual(result['metrics']['host_watts']['reduction_percent'], 20)
        self.assertEqual(result['metrics']['controller_watts']['status'], 'not-measured')
        self.assertFalse(result['independently_verified'])
        self.assertIsNone(a.compare(fixture(power=0), fixture('motion', 0))['metrics']['host_watts']['reduction_percent'])

    def test_missing_failed_mismatched_and_short_records_rejected(self):
        for mutate in [lambda r: r['checks']['sleep_wake'].update(result='fail'),
                       lambda r: r['checks']['button_wake'].update(result='not-run'),
                       lambda r: r['checks']['button_wake'].update(result='not-applicable'),
                       lambda r: r['checks']['active_input'].update(evidence=''),
                       lambda r: r['context'].update(firmware='different'),
                       lambda r: r['trials'].pop(),
                       lambda r: r['trials'][0].update(duration_seconds=61)]:
            candidate = fixture('pointer'); mutate(candidate)
            with self.assertRaises(a.Invalid): a.compare(fixture(), candidate)

    def test_numeric_bounds_and_units(self):
        for value in (float('nan'), float('inf'), -1, True, '10', 1_000_001, 10**1000):
            r = fixture(); r['trials'][0]['host_watts'] = value
            with self.assertRaises(a.Invalid): a.validate(r)
        for key in ('model', 'revision', 'architecture', 'output'):
            r = fixture(); r['context'][key] = 'invalid'
            with self.assertRaises(a.Invalid): a.validate(r)
        r = fixture(); r['trials'][0]['battery_percent'] = 50
        with self.assertRaises(a.Invalid): a.validate(r)

    def test_size_and_cli(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)/'record.json'; path.write_text(json.dumps(a.template()))
            result = subprocess.run([sys.executable, 'scripts/check-acceptance.py', 'check', str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)['status'], 'incomplete')
            for malformed in ('{"schema":1,"schema":2}', '{"value":NaN}'):
                path.write_text(malformed)
                with self.assertRaises(a.Invalid): a.load(path)
            path.write_text('['*2000 + ']'*2000)
            result = subprocess.run([sys.executable, 'scripts/check-acceptance.py', 'check', str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('Traceback', result.stderr)
            path.write_bytes(b' '*(a.MAX_BYTES+1))
            with self.assertRaises(a.Invalid): a.load(path)
            result = subprocess.run([sys.executable, 'scripts/check-acceptance.py', 'check', str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)


if __name__ == '__main__': unittest.main()
