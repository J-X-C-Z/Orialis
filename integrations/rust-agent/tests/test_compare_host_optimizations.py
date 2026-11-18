import json
from pathlib import Path
import tempfile
import unittest
from compare_host_optimizations import ORDERS, summarize
from test_compare_host_releases import case


class OptimizationMatrixTests(unittest.TestCase):
    def test_each_variant_occupies_each_order_position_once(self):
        expected = {'control', 'empty', 'reaper', 'combined'}
        for order in ORDERS:
            self.assertEqual(set(order), expected)
        for index in range(4):
            self.assertEqual({order[index] for order in ORDERS}, expected)

    def test_separate_variants_and_model_delays_never_pool_together(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            for delay, variant, latency in [(0, 'control', 1), (0, 'empty', 2), (20, 'control', 21)]:
                path = root/f'delay-{delay}'/'round-1'/variant/'trial-1-base'
                path.mkdir(parents=True)
                (path/'text.json').write_text(json.dumps(case([latency], 1, 1)))
            result = summarize(root)
            self.assertEqual(len(result), 3)
            self.assertEqual({(r['delay'], r['variant'], r['p50_ms']) for r in result}, {('delay-0', 'control', 1), ('delay-0', 'empty', 2), ('delay-20', 'control', 21)})
            self.assertTrue(all(r['submit_to_primary_ms']['p50'] is None for r in result))


if __name__ == '__main__':
    unittest.main()
