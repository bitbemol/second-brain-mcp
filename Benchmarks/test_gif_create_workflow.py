import copy
import unittest

from gif_create_workflow import evaluate


def call(text, milliseconds=100):
    return {'success': True, 'elapsed_ms': milliseconds, 'request_bytes': 100,
            'response_bytes': 300, 'response': {'result': {
                'content': [{'type': 'text', 'text': text}],
                'structuredContent': {'revision': 'sha256:' + 'c' * 64}}}}


def fixture():
    facts = {'width': 64, 'height': 48, 'frames': 120, 'duration_ms': 26400,
             'bytes': 1000, 'sha256': 'c' * 64}
    rows = []
    for sample in range(30):
        for variant in (['baseline', 'candidate'] if sample % 2 == 0
                        else ['candidate', 'baseline']):
            root = '/private/tmp/gif-check/vault-' + variant + '-' + str(sample)
            rows.append({'sample': sample, 'variant': variant, 'vault': root,
                         'source_unchanged': True, 'facts': dict(facts),
                         'create': call('Created notes/import.gif as animated GIF 64×48, '
                                        + ('25.9s' if variant == 'baseline' else '26.4s')
                                        + ', 120 frames, 1000 B'),
                         'read': call('GIF 64×48, 1000 B, 120 frames, 26.4s. No images returned.'),
                         'initialize': call('initialized'),
                         'exit': {'exit_code': 0, 'forced_signals': 0},
                         'cleanup': [{'removed_owned_directory': root}],
                         'cleanup_errors': [], 'cleanup_verified_absent': True})
    return {'samples_per_variant': 30, 'baseline_sha256': 'a' * 64,
            'candidate_sha256': 'b' * 64, 'fixture': {'width': 64, 'height': 48,
            'frames': 259, 'fps': 10, 'duration_ms': 25900,
            'source_sha256': 'd' * 64}, 'rows': rows, 'execution_complete': True}


class GIFCreateCheckerTests(unittest.TestCase):
    def assert_rejected(self, report):
        self.assertFalse(evaluate(report)['passed'])

    def test_complete_grid_passes_and_baseline_metadata_mismatch_is_not_failure(self):
        self.assertTrue(evaluate(fixture())['passed'])

    def test_malformed_row_grid_is_rejected_without_crashing(self):
        for value in (None, {}, [None]):
            report = fixture()
            report['rows'] = value
            self.assert_rejected(report)

    def test_empty_grid(self):
        report = fixture()
        report['rows'] = []
        self.assert_rejected(report)

    def test_missing_and_duplicate_rows(self):
        for duplicate in (False, True):
            report = fixture()
            report['rows'].pop()
            if duplicate:
                report['rows'].append(copy.deepcopy(report['rows'][0]))
            self.assert_rejected(report)

    def test_raw_tool_errors_are_not_fast_successes(self):
        for field in ('create', 'read', 'initialize'):
            report = fixture()
            report['rows'][1][field]['response']['result']['isError'] = True
            self.assert_rejected(report)

    def test_bad_candidate_metadata_or_revision(self):
        for field in ('text', 'revision'):
            report = fixture()
            body = report['rows'][1]['create']['response']['result']
            if field == 'text':
                body['content'][0]['text'] = body['content'][0]['text'].replace('26.4s', '25.9s')
            else:
                body['structuredContent']['revision'] = 'sha256:' + 'e' * 64
            self.assert_rejected(report)

    def test_invalid_encoded_facts(self):
        for key, value in [('frames', 119), ('duration_ms', 25900),
                           ('width', 63), ('bytes', 0), ('sha256', 'wrong')]:
            report = fixture()
            report['rows'][1]['facts'][key] = value
            self.assert_rejected(report)

    def test_failed_exit_or_cleanup(self):
        for kind in ('exit', 'forced', 'cleanup', 'absent', 'source'):
            report = fixture()
            row = report['rows'][1]
            if kind == 'exit': row['exit']['exit_code'] = -11
            if kind == 'forced': row['exit']['forced_signals'] = 1
            if kind == 'cleanup': row['cleanup_errors'] = ['failure']
            if kind == 'absent': row['cleanup_verified_absent'] = False
            if kind == 'source': row['source_unchanged'] = False
            self.assert_rejected(report)

    def test_bad_timings_and_counter_shapes(self):
        for value in (float('nan'), float('inf'), -1, True):
            report = fixture()
            report['rows'][1]['create']['elapsed_ms'] = value
            self.assert_rejected(report)

    def test_predeclared_no_regression_gate(self):
        report = fixture()
        for row in report['rows']:
            if row['variant'] == 'candidate':
                row['create']['elapsed_ms'] = 121
        self.assert_rejected(report)

    def test_preexisting_support_is_never_claimed_for_cleanup(self):
        import tempfile
        from pathlib import Path
        from unittest.mock import patch
        import mcp_stdio
        from gif_create_workflow import run_one
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            preexisting = root / 'preexisting'
            preexisting.mkdir()
            prior_root = mcp_stdio.ROOT
            mcp_stdio.ROOT = root
            try:
                with patch('gif_create_workflow.support_candidates', return_value=[preexisting]), \
                     patch('gif_create_workflow.cleanup_fixture') as cleanup:
                    row = run_one(root / 'unused', 'baseline', 0, root,
                                  root / 'unused.mov', 'd' * 64)
                    self.assertIn('error', row)
                    self.assertEqual(cleanup.call_args.args[2], [])
                    self.assertTrue(preexisting.is_dir())
            finally:
                mcp_stdio.ROOT = prior_root

    def test_incomplete_execution_and_alternating_order(self):
        report = fixture()
        report['execution_complete'] = False
        self.assert_rejected(report)
        report = fixture()
        report['rows'][0], report['rows'][1] = report['rows'][1], report['rows'][0]
        self.assert_rejected(report)


if __name__ == '__main__':
    unittest.main()
