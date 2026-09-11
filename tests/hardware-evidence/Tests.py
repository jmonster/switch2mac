"""Synthetic fixtures only. No test result is a hardware or power observation."""
import copy
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOL = Path(__file__).resolve().parents[2] / 'scripts/hardware-evidence.py'
q = runpy.run_path(str(TOOL))


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def artifact(self, path, data=b'SYNTHETIC: not a physical observation\n'):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        return {'path': path, 'sha256': hashlib.sha256(data).hexdigest()}

    def envelope(self, prefix='a', offset=0):
        value = q['template']()
        record = value['record']
        record['context'].update(revision='a' * 40, model='2069', firmware='fixture-1',
                                 macos='15.7', architecture='arm64', output='sdl',
                                 game_build='synthetic', conditions='SYNTHETIC same physical-unit placeholder')
        reference = self.artifact(prefix + '-observation.txt')
        for check in record['checks']:
            record['checks'][check] = {'result': 'pass', 'evidence': 'Synthetic regression observation'}
            value['evidence'][check] = [reference]
        for index in range(3):
            data = ('time_seconds,power_watts\n0,{}\n10,{}\n'.format(10 + offset + index, 10 + offset + index)).encode()
            trace = self.artifact('{}-{}.csv'.format(prefix, index), data)
            record['trials'].append({'duration_seconds': 10, 'host_watts': 10 + offset + index, 'controller_watts': None})
            value['power_traces'].append({'host_watts': trace, 'controller_watts': None})
        return value

    def validate(self, value):
        with q['EvidenceRoot'](self.root) as root:
            return q['validate'](value, root)

    def test_incomplete_template_and_empty_matrix_do_not_claim_support(self):
        result = self.validate(q['template']())
        self.assertEqual(result['status'], 'incomplete')
        self.assertFalse(result['eligible_hardware_pass'])
        with q['EvidenceRoot'](self.root) as root:
            self.assertEqual(q['matrix']([], root)['rows'], [])

    def test_kind_failure_and_missing_artifact_gates(self):
        value = self.envelope()
        self.assertTrue(self.validate(value)['eligible_hardware_pass'])
        for kind in ('simulation', 'runtime'):
            value['kind'] = kind
            self.assertFalse(self.validate(value)['eligible_hardware_pass'])
        value['kind'] = 'hardware'
        value['record']['checks']['reconnect']['result'] = 'fail'
        self.assertFalse(self.validate(value)['eligible_hardware_pass'])
        value['evidence']['reconnect'] = []
        with self.assertRaises(q['Invalid']):
            self.validate(value)

    def test_time_weighted_power_is_not_sample_average(self):
        data = b'time_seconds,power_watts\n0,0\n1,10\n10,10\n'
        result = q['power'](data)
        self.assertEqual(result['mean_watts'], 9.5)
        self.assertEqual(result['duration_seconds'], 10)
        self.assertEqual(result['max_gap_seconds'], 9)
        self.assertNotEqual(result['mean_watts'], 20 / 3)

    def test_bad_trace_units_timestamps_values_and_rows(self):
        for data in (b't,watts\n0,10\n1,10\n', b'time_seconds,power_watts\n0,1\n0,2\n',
                     b'time_seconds,power_watts\n1,1\n0,2\n', b'time_seconds,power_watts\n0,nan\n1,2\n',
                     b'time_seconds,power_watts\n0,inf\n1,2\n', b'time_seconds,power_watts\n0,-1\n1,2\n',
                     b'time_seconds,power_watts\n0,1\n', b'time_seconds,power_watts\n0,1,2\n1,2\n'):
            with self.subTest(data=data), self.assertRaises(ValueError):
                q['power'](data)

    def test_recorded_power_and_duration_must_match_trace(self):
        baseline = self.envelope()
        for field, changed in (('host_watts', 999), ('duration_seconds', 11)):
            value = copy.deepcopy(baseline)
            value['record']['trials'][0][field] = changed
            with self.subTest(field=field), self.assertRaises(q['Invalid']):
                self.validate(value)
        value = copy.deepcopy(baseline)
        value['record']['trials'][0]['host_watts'] = None
        with self.assertRaises(q['Invalid']):
            self.validate(value)

    def test_hash_tampering_empty_artifact_and_duplicate_trials(self):
        value = self.envelope()
        (self.root / 'a-observation.txt').write_bytes(b'TAMPERED')
        with self.assertRaises(q['Invalid']):
            self.validate(value)
        value = self.envelope()
        value['evidence']['active_input'] = [self.artifact('empty.txt', b'')]
        with self.assertRaises(q['Invalid']):
            self.validate(value)
        value = self.envelope()
        value['record']['trials'][1] = copy.deepcopy(value['record']['trials'][0])
        value['power_traces'][1] = copy.deepcopy(value['power_traces'][0])
        with self.assertRaises(q['Invalid']):
            self.validate(value)

    def test_paths_symlinks_directories_and_pipe_are_refused(self):
        self.artifact('safe.txt')
        (self.root / 'alias').symlink_to(self.root / 'safe.txt')
        (self.root / 'folder').mkdir()
        (self.root / 'linkdir').symlink_to(self.root / 'folder', target_is_directory=True)
        for path in ('../safe.txt', '/etc/passwd', 'a//b', 'a/./b', 'a\\b', 'a\x00b', 'alias', 'folder', 'linkdir/file'):
            with self.subTest(path=path), q['EvidenceRoot'](self.root) as root, self.assertRaises((ValueError, OSError)):
                root.read(path)
        os.mkfifo(self.root / 'pipe')
        result = subprocess.run([sys.executable, str(TOOL), '--root', str(self.root), 'check', 'pipe'],
                                capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn('Traceback', result.stderr)

    def test_size_limits_aggregate_and_changed_file(self):
        self.artifact('large', b'12345')
        with q['EvidenceRoot'](self.root) as root, self.assertRaises(q['Invalid']):
            root.read('large', limit=4)
        with patch.dict(q['EvidenceRoot'].read.__globals__, MAX_TOTAL=4):
            with q['EvidenceRoot'](self.root) as root, self.assertRaises(q['Invalid']):
                root.read('large')
        read = os.read
        def changed(fd, count):
            data = read(fd, count)
            (self.root / 'large').write_bytes(b'changed length')
            return data
        with q['EvidenceRoot'](self.root) as root, patch('os.read', side_effect=changed), self.assertRaises(q['Invalid']):
            root.read('large')

    def test_json_duplicate_deep_and_invalid_constants_fail_cleanly(self):
        for text in ('{"kind":1,"kind":2}', '{"x":NaN}', '[' * 1100 + '0' + ']' * 1100,
                     '{"x":' + '9' * 10000 + '}'):
            self.artifact('bad.json', text.encode())
            result = subprocess.run([sys.executable, str(TOOL), '--root', str(self.root), 'check', 'bad.json'],
                                    capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('Traceback', result.stderr)

    def test_matched_profiles_and_discovery_comparison(self):
        a, b = self.envelope('a'), self.envelope('b', -4)
        b['record']['profile'] = 'gamepad'
        with q['EvidenceRoot'](self.root) as root:
            result = q['compare'](a, b, root)
        self.assertEqual(result['changed_factor'], 'sensor_profile')
        self.assertEqual(result['metrics']['host_watts']['delta_watts'], -4)
        self.assertEqual(result['metrics']['controller_watts']['status'], 'not-measured')
        b['record']['profile'] = 'compatibility'; b['discovery_mode'] = 'quiet-when-ready'
        with q['EvidenceRoot'](self.root) as root:
            self.assertEqual(q['compare'](a, b, root)['changed_factor'], 'discovery_mode')

    def test_compare_rejects_mismatch_simulation_failures_and_reused_traces(self):
        a, original = self.envelope('a'), self.envelope('b', -4)
        original['record']['profile'] = 'gamepad'
        for mutate in (lambda b: b.update(kind='simulation'),
                       lambda b: b.update(discovery_mode='quiet-when-ready'),
                       lambda b: b['record']['context'].update(firmware='other'),
                       lambda b: b['record']['checks']['reconnect'].update(result='fail'),
                       lambda b: b.update(power_traces=a['power_traces'], record=dict(b['record'], trials=a['record']['trials']))):
            b = copy.deepcopy(original); mutate(b)
            with q['EvidenceRoot'](self.root) as root, self.assertRaises(q['Invalid']):
                q['compare'](a, b, root)

    def test_matrix_keeps_simulation_and_incomplete_results_separate(self):
        a, b = self.envelope('a'), q['template']('runtime')
        a['kind'] = 'simulation'
        self.artifact('a.json', json.dumps(a).encode()); self.artifact('b.json', json.dumps(b).encode())
        with q['EvidenceRoot'](self.root) as root:
            result = q['matrix'](['a.json', 'b.json'], root)
        self.assertTrue(all(not row['eligible_hardware_pass'] for row in result['rows']))
        self.assertEqual({row['status'] for row in result['rows']}, {'reported-complete', 'incomplete'})
        self.assertNotIn('conditions', result['rows'][0])

    def test_cli_trace_outputs_recomputable_reference(self):
        ref = self.artifact('meter.csv', b'time_seconds,power_watts\n0,3\n2,7\n')
        result = subprocess.run([sys.executable, str(TOOL), '--root', str(self.root), 'trace', 'meter.csv'],
                                capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        self.assertEqual(data['reference'], ref)
        self.assertEqual(data['mean_watts'], 5)


if __name__ == '__main__':
    unittest.main()
