"""Harness result integrity tests. All MCP/native execution is replaced by bounded fakes."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import native_workflow


class NativeWorkflowReportTests(unittest.TestCase):
    def run_main(self, root, operation, cases=('ordinary', 'metadata32'), samples=2, assets_error=None):
        binary = root / 'fixture-binary'
        binary.write_bytes(b'not-executed')
        arguments = ['native_workflow.py', '--binary', str(binary),
                     '--sha', hashlib.sha256(binary.read_bytes()).hexdigest(),
                     '--samples', str(samples), '--cases', *cases]
        with patch('sys.argv', arguments), patch.object(native_workflow, 'artifact_root', return_value=root), \
             patch.object(native_workflow, 'assets_for', side_effect=assets_error, return_value={}), \
             patch.object(native_workflow, 'guarded_case', side_effect=operation):
            native_workflow.main()

    def test_artifact_compaction_error_fails_the_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def operation(binary, case, assets, row):
                row['calls'] = [{'response': {'result': {'content': [
                    {'type': 'image', 'data': 'not-valid-base64'}
                ]}}}]

            with self.assertRaises(RuntimeError):
                self.run_main(root, operation, cases=('ordinary',), samples=1)
            report = json.loads((root / 'native-workflow.json').read_text())
            self.assertFalse(report['complete_and_correct'])
            self.assertFalse(report['samples'][0]['all_checks_passed'])
            self.assertTrue(report['samples'][0]['artifact_compaction_errors'])

    def test_partial_failure_preserves_the_requested_grid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def operation(binary, case, assets, row):
                if case == 'metadata32':
                    raise RuntimeError('planned native failure')

            with self.assertRaisesRegex(RuntimeError, 'planned native failure'):
                self.run_main(root, operation)
            report = json.loads((root / 'native-workflow.json').read_text())
            self.assertEqual(report['cases_requested'], ['ordinary', 'metadata32'])
            self.assertEqual(report['expected_case_index_grid'], [
                {'index': 0, 'case': 'ordinary'}, {'index': 0, 'case': 'metadata32'},
                {'index': 1, 'case': 'ordinary'}, {'index': 1, 'case': 'metadata32'},
            ])
            self.assertFalse(report['complete_and_correct'])
            self.assertEqual(len(report['samples']), 2)

    def test_fixture_failure_is_an_incomplete_empty_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(RuntimeError, 'fixture failed'):
                self.run_main(root, lambda *args: None, assets_error=RuntimeError('fixture failed'))
            report = json.loads((root / 'native-workflow.json').read_text())
            self.assertFalse(report['complete_and_correct'])
            self.assertEqual(report['samples'], [])
            self.assertEqual(len(report['expected_case_index_grid']), 4)

    def test_success_requires_every_requested_pair(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.run_main(root, lambda *args: None)
            report = json.loads((root / 'native-workflow.json').read_text())
            self.assertTrue(report['complete_and_correct'])
            observed = [{'index': row['index'], 'case': row['case']} for row in report['samples']]
            self.assertEqual(observed, report['expected_case_index_grid'])
            self.assertTrue(all(row['all_checks_passed'] for row in report['samples']))

    def test_repeated_case_selection_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(SystemExit) as raised:
                self.run_main(root, lambda *args: None, cases=('ordinary', 'ordinary'), samples=1)
            self.assertEqual(raised.exception.code, 2)
            self.assertFalse((root / 'native-workflow.json').exists())


if __name__ == '__main__':
    unittest.main()
