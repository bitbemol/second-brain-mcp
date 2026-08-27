"""Isolated benchmark reliability tests; never launches the MCP or touches user vaults."""
import contextlib
import hashlib
import importlib.metadata
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import mcp_stdio
import schema_contract
import tool_workflow


class FakeRPC:
    initialize_error = None
    close_error = None
    exit_info = {'exit_code': 0, 'forced_signals': 0}

    def __init__(self, *args):
        pass

    def initialize(self):
        if self.initialize_error:
            raise self.initialize_error
        return {'success': True}

    def close(self):
        if self.close_error:
            raise self.close_error
        return dict(self.exit_info)


class ContractValidator:
    """Keeps these lifecycle tests independent of the production schema contract."""
    def __init__(self, schema):
        pass

    def iter_errors(self, instance):
        coverage = instance['coverage']
        invalid = (coverage['complete'] and 'failed_files' in coverage
                   or not coverage['complete'] and 'failed_files' not in coverage
                   or bool(instance['results']))
        return [type('Error', (), {'message': 'expected negative case'})()] if invalid else []


class BenchmarkReliabilityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='benchmark-unit-')
        self.root = Path(self.directory.name)
        FakeRPC.initialize_error = None
        FakeRPC.close_error = None
        FakeRPC.exit_info = {'exit_code': 0, 'forced_signals': 0}

    def tearDown(self):
        self.directory.cleanup()

    def arguments(self, script):
        return [script, '--binary', sys.executable,
                '--sha', hashlib.sha256(Path(sys.executable).read_bytes()).hexdigest(),
                '--label', 'test', '--output', str(self.root / 'evidence')]

    def run_schema(self):
        tools = {name: {'outputSchema': {}} for name in ['search_vault', 'query_links']}
        with patch.object(sys, 'argv', self.arguments('schema_contract.py')), \
             patch.object(schema_contract, 'RPC', FakeRPC), \
             patch.object(schema_contract, 'support_candidates', return_value=[]), \
             patch.object(schema_contract, 'discover', return_value=(tools, {'discovered': True})), \
             patch.object(schema_contract, 'Draft202012Validator', ContractValidator), \
             contextlib.redirect_stdout(io.StringIO()):
            try:
                schema_contract.main()
            except BaseException as error:
                return error
        return None

    def report(self):
        return json.loads((self.root / 'evidence/test.json').read_text())

    def child(self, code='import time; time.sleep(10)'):
        popen = subprocess.Popen
        with patch.object(mcp_stdio.subprocess, 'Popen',
                          side_effect=lambda command, **kwargs: popen(
                              [sys.executable, '-c', code], **kwargs)):
            client = mcp_stdio.RPC(Path(sys.executable), self.root, False)
        client.request_timeout = .10
        return client

    def stop_child(self, client):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(client.p.pid, signal.SIGKILL)
        client.close()

    def test_blocked_request_write_has_a_deadline(self):
        client = self.child()
        failures = []
        def begin():
            try:
                client.begin('tools/call', {'content': 'a' * (1024 * 1024)})
            except BaseException as error:
                failures.append(error)
        thread = threading.Thread(target=begin, daemon=True)
        thread.start()
        thread.join(.5)
        completed = not thread.is_alive()
        try:
            self.assertTrue(completed, 'Request write blocked before response timeout could start')
            self.assertEqual(len(failures), 1)
            self.assertIsInstance(failures[0], TimeoutError)
        finally:
            self.stop_child(client)
            thread.join(1)

    def test_response_wait_uses_original_request_deadline(self):
        client = self.child()
        try:
            ticket = client.begin('ping', {})
            time.sleep(.12)
            started = time.monotonic()
            with self.assertRaises(TimeoutError):
                client.wait(ticket, timeout=.20)
            self.assertLess(time.monotonic() - started, .08,
                            'Response timeout restarted after the request deadline')
        finally:
            self.stop_child(client)

    def test_optimized_mode_is_rejected_before_argument_processing(self):
        for script in ['tool_workflow.py', 'schema_contract.py']:
            with self.subTest(script=script):
                result = subprocess.run([sys.executable, '-B', '-O',
                    str(Path(__file__).parent / script), '--help'],
                    capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0, 'Optimized mode disables safety assertions')
                self.assertIn('optimized', result.stderr.lower())

    def test_schema_requires_clean_process_exit(self):
        FakeRPC.exit_info = {'exit_code': 9, 'forced_signals': 0}
        error = self.run_schema()
        self.assertIsInstance(error, SystemExit)
        self.assertNotEqual(error.code, 0)
        self.assertFalse(self.report()['all_passed'])
        self.assertIn('shutdown_error', self.report())

    def test_schema_rejects_forced_shutdown(self):
        FakeRPC.exit_info = {'exit_code': 0, 'forced_signals': 1}
        error = self.run_schema()
        self.assertIsInstance(error, SystemExit)
        self.assertNotEqual(error.code, 0)
        self.assertFalse(self.report()['all_passed'])

    def test_schema_preserves_evidence_when_cleanup_fails(self):
        with patch.object(mcp_stdio.shutil, 'rmtree', side_effect=PermissionError('fixture cleanup')):
            self.run_schema()
        report = self.report()
        self.assertEqual(len(report['cases']), 7)
        self.assertFalse(report['all_passed'])
        self.assertIn('fixture cleanup', str(report['cleanup_errors']))

    def test_schema_preserves_primary_and_shutdown_failures(self):
        FakeRPC.initialize_error = ValueError('primary initialize failure')
        FakeRPC.close_error = RuntimeError('secondary shutdown failure')
        self.run_schema()
        report = self.report()
        self.assertIn('primary initialize failure', report['error'])
        self.assertIn('secondary shutdown failure', report['shutdown_error'])
        self.assertFalse(report['all_passed'])
        self.assertTrue(list((self.root / 'evidence').glob('schema-contract-*')),
                        'Do not delete a vault when child exit is unconfirmed')

    def test_workflow_preserves_primary_and_shutdown_failures(self):
        FakeRPC.initialize_error = ValueError('primary initialize failure')
        FakeRPC.close_error = RuntimeError('secondary shutdown failure')
        with patch.object(sys, 'argv', self.arguments('tool_workflow.py') + ['--samples', '1']), \
             patch.object(tool_workflow, 'RPC', FakeRPC), \
             patch.object(tool_workflow, 'support_candidates', return_value=[]), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(ValueError):
                tool_workflow.main()
        row = self.report()['samples'][0]
        self.assertIn('primary initialize failure', row['error'])
        self.assertIn('secondary shutdown failure', row['shutdown_error'])
        self.assertFalse(row['all_tools_correct'])

    def test_large_request_success_preserves_complete_frame_and_clean_shutdown(self):
        code = (
            "import json,sys\n"
            "for line in sys.stdin:\n"
            " value=json.loads(line)\n"
            " print(json.dumps({'jsonrpc':'2.0','id':value['id'],"
            "'result':{'bytes':len(value['params']['content'])}}),flush=True)\n"
        )
        client = self.child(code)
        client.request_timeout = 2
        try:
            row = client.wait(client.begin('echo', {'content': 'a' * (1024 * 1024)}))
            self.assertTrue(row['success'])
            self.assertEqual(row['response']['result']['bytes'], 1024 * 1024)
            self.assertGreater(row['request_bytes'], 1024 * 1024)
        finally:
            exited = client.close()
        self.assertEqual(exited['exit_code'], 0)
        self.assertEqual(exited['forced_signals'], 0)

    def test_schema_clean_success_is_preserved(self):
        error = self.run_schema()
        self.assertIsInstance(error, SystemExit)
        self.assertEqual(error.code, 0)
        self.assertTrue(self.report()['all_passed'])
        self.assertFalse(self.report()['cleanup_errors'])
        self.assertFalse(list((self.root / 'evidence').glob('schema-contract-*')))

    def test_cleanup_refuses_substituted_vault_symlink(self):
        root = self.root.resolve()
        vault = root / 'owned'
        vault.mkdir()
        identity = vault.lstat()
        vault.rename(root / 'original-owned')
        target = root / 'unrelated'
        target.mkdir()
        (target / 'sentinel').write_text('preserve')
        vault.symlink_to(target, target_is_directory=True)
        report = {}
        with patch.object(mcp_stdio, 'ROOT', root):
            self.assertFalse(mcp_stdio.cleanup_fixture(vault, identity, [], report))
        self.assertEqual((target / 'sentinel').read_text(), 'preserve')
        self.assertTrue(vault.is_symlink())
        self.assertEqual(len(report['cleanup_errors']), 1)

    def test_workflow_records_actual_validator_version(self):
        with patch.object(sys, 'argv', self.arguments('tool_workflow.py') + ['--samples', '1']), \
             patch.object(tool_workflow, 'sample', return_value={}), \
             patch.object(importlib.metadata, 'version', return_value='fixture-9.0'), \
             contextlib.redirect_stdout(io.StringIO()):
            tool_workflow.main()
        self.assertEqual(self.report()['schema_validator'], 'jsonschemafixture-9.0/Draft202012')


if __name__ == '__main__':
    unittest.main()
