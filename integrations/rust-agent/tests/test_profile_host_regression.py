import json
from pathlib import Path
import tempfile
import unittest
from profile_host_regression import map_category, request_segments


class ProfileRegressionTests(unittest.TestCase):
    def test_map_categories_do_not_call_file_rss_heap(self):
        self.assertEqual(map_category('/app/agent', '/app/agent'), 'executable')
        self.assertEqual(map_category('[anon]', '/app/agent'), 'anonymous')
        self.assertEqual(map_category('[heap]', '/app/agent'), 'heap')
        self.assertEqual(map_category('/tmp/a.sqlite-shm', '/app/agent'), 'sqlite_shared_memory')

    def test_missing_segments_stay_missing_and_quantiles_pool_rows(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            for index, values in enumerate(([1], [2, 3, 4])):
                path = root / f'trial-{index}'
                path.mkdir()
                case = {'profile': 'base', 'workload': 'text', 'primary_records': [],
                        'rows': [{'marker': f'{index}-{v}', 'ok': True, 'latency_ms': v} for v in values]}
                (path / 'text.json').write_text(json.dumps(case))
            report, = request_segments(root)
            self.assertEqual(report['segments']['latency_ms']['p50'], 2)
            missing = report['segments']['model_finish_to_mobile_ms']
            self.assertIsNone(missing['p50'])
            self.assertEqual(missing['missing'], 4)


if __name__ == '__main__':
    unittest.main()
