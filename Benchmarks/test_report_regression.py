import base64
import io
import unittest

from PIL import Image
from report_regression import (CANVAS, REPLACEMENT, SOURCE, MARKDOWN, CASE_IDS,
                               ERRORS, digest, evaluate, png_bytes, expected_call, initialize_params)


def valid_report():
    rows = []
    files = {
        'malformed_har': {'notes/invalid.har': None},
        'repeated_separator': {'notes/invalid.json': None},
        'canvas_append': {'notes/map.canvas': digest(CANVAS.encode())},
        'canvas_replace': {'notes/map.canvas': digest(REPLACEMENT.encode())},
        'stale_update': {'notes/source.json': digest(SOURCE.encode())},
        'stale_move': {'notes/source.json': digest(SOURCE.encode()), 'notes/moved.json': None},
        'placeholder_move': {'notes/ticket/attachments/.gitkeep.md': None,
                             'notes/completed/ticket/attachments/.gitkeep.md': digest(b'')},
        'env_move': {'notes/blocked/.env': digest(b'fixture-only'),
                    'notes/completed/blocked/.env': None},
    }
    for identifier, name in enumerate(CASE_IDS, 3):
        body = {'content': [{'type': 'text', 'text': 'okay'}], 'structuredContent': {}}
        row = {'case': name, 'success': True, 'elapsed_ms': 1, 'request_bytes': 100,
               'response_bytes': 100, 'request': {'jsonrpc': '2.0', 'id': identifier,
                   'method': 'tools/call', 'params': expected_call(name)},
               'response': {'jsonrpc': '2.0', 'id': identifier, 'result': body}}
        if name in ERRORS:
            code, state, detail = ERRORS[name]
            body.update(isError=True, structuredContent={'error': {
                'code': code, 'state': state, 'retry': 'correct_request'}})
            body['content'][0]['text'] = detail + (' use replace' if name == 'canvas_append' else '')
            row['success'] = False
        if name in files:
            row['files'] = files[name]
        if name == 'canvas_replace':
            body['structuredContent']['revision'] = 'sha256:' + digest(REPLACEMENT.encode())
        if name in ('broad_coverage', 'metadata_coverage'):
            body['structuredContent'] = {'results': [], 'coverage': {
                'complete': False, 'failed_files': 1,
                'failed_by_format': {'har' if name == 'broad_coverage' else 'markdown': 1},
                'complete_formats': ['markdown'] if name == 'broad_coverage' else []}}
        if name.startswith('render_'):
            payloads = [png_bytes(64, 48)]
            if name == 'render_gif':
                payloads = []
                for source_index in (0, 3, 5, 8, 11, 14, 16, 19):
                    output = io.BytesIO()
                    Image.new('RGB', (64, 48), (source_index * 11, 120, 255 - source_index * 11)).save(output, format='PNG')
                    payloads.append(output.getvalue())
            body['content'].extend({'type': 'image', 'mimeType': 'image/png',
                                    'data': base64.b64encode(payload).decode()} for payload in payloads)
        if name.startswith(('png_', 'gif_')):
            row['concurrent_batch'] = name.split('_')[0]
            if '_search' in name:
                body['structuredContent']['results'] = [{'path': 'notes/unrelated.md', 'format': 'markdown'}]
            if name.endswith('_metadata'):
                body['structuredContent']['revision'] = 'sha256:' + digest(MARKDOWN.encode())
        rows.append(row)
    return {'calls': rows, 'execution_complete': True, 'binary_sha256': 'a' * 64,
            'verified_binary_sha256': 'a' * 64,
            'initialize': {'success': True,
                'request': {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': initialize_params()},
                'response': {'jsonrpc': '2.0', 'id': 1, 'result': {}}},
            'exit': {'exit_code': 0, 'forced_signals': 0}, 'cleanup_verified_absent': True,
            'vault': '/private/tmp/owned-replay',
            'cleanup': [{'removed_owned_directory': '/private/tmp/owned-replay'}],
            'readonly_files_before': {'notes/source.json': 'b' * 64},
            'readonly_files_after': {'notes/source.json': 'b' * 64}}


class ReportReplayOracleTests(unittest.TestCase):
    def test_wrong_method_and_tool_cannot_inherit_case_success(self):
        for key, value in (('method', 'notifications/initialized'),
                           ('params', {'name': 'delete_file', 'arguments': {}})):
            report = valid_report()
            report['calls'][0]['request'][key] = value
            self.assertFalse(evaluate(report)['passed'])

    def test_json_boolean_cannot_be_substituted_with_numeric_one(self):
        report = valid_report()
        report['calls'][12]['request']['params']['arguments']['render'] = 1
        self.assertFalse(evaluate(report)['passed'])

    def test_changed_arguments_cannot_inherit_expected_error(self):
        report = valid_report()
        report['calls'][1]['request'].update(
            jsonrpc='2.0', method='tools/call',
            params={'name': 'create_file', 'arguments': {
                'format': 'json', 'path': 'notes/elsewhere.json', 'content': '{}'}})
        self.assertFalse(evaluate(report)['passed'])

    def test_initialize_id_must_match_its_recorded_request(self):
        report = valid_report()
        report['initialize']['request']['id'] = 999
        self.assertFalse(evaluate(report)['passed'])

    def test_initialize_id_cannot_be_reused_for_a_tool_response(self):
        report = valid_report()
        identifier = report['calls'][0]['request']['id']
        report['initialize']['request']['id'] = identifier
        report['initialize']['response']['id'] = identifier
        self.assertFalse(evaluate(report)['passed'])

    def test_valid_complete_report(self):
        self.assertTrue(evaluate(valid_report())['passed'])

    def test_missing_duplicate_or_malformed_grid(self):
        for value in (None, [], [None]):
            report = valid_report()
            report['calls'] = value
            self.assertFalse(evaluate(report)['passed'])

    def test_wrong_phase_is_not_accepted_as_safe_failure(self):
        report = valid_report()
        report['calls'][1]['response']['result']['structuredContent']['error']['state'] = 'unknown'
        self.assertFalse(evaluate(report)['passed'])

    def test_global_completeness_cannot_hide_metadata_narrowing(self):
        report = valid_report()
        report['calls'][11]['response']['result']['structuredContent']['coverage']['complete_formats'] = ['json']
        self.assertFalse(evaluate(report)['passed'])

    def test_unrelated_image_and_body_are_rejected(self):
        for block in ({'type': 'image', 'mimeType': 'image/png', 'data': ''},
                      {'type': 'text', 'text': 'PRIVATE_BODY_MARKER'}):
            report = valid_report()
            report['calls'][13]['response']['result']['content'].append(block)
            self.assertFalse(evaluate(report)['passed'])

    def test_wrong_rendered_pixels_are_rejected(self):
        report = valid_report()
        report['calls'][16]['response']['result']['content'][1]['data'] = base64.b64encode(png_bytes(64, 48)).decode()
        self.assertFalse(evaluate(report)['passed'])

    def test_filesystem_changes_fail_even_with_correct_error(self):
        report = valid_report()
        report['calls'][1]['files']['notes/invalid.har'] = 'c' * 64
        self.assertFalse(evaluate(report)['passed'])

    def test_shutdown_cleanup_and_identity_fail_closed(self):
        for key, value in [('cleanup_verified_absent', False), ('shutdown_error', 'failed'),
                           ('verified_binary_sha256', 'b' * 64), ('execution_complete', False)]:
            report = valid_report()
            report[key] = value
            self.assertFalse(evaluate(report)['passed'])

    def test_initialize_raw_error_cannot_hide_behind_success_flag(self):
        report = valid_report()
        report['initialize']['response'] = {'jsonrpc': '2.0', 'id': 1, 'error': {'code': -1}}
        self.assertFalse(evaluate(report)['passed'])

    def test_duplicate_rpc_ids_are_not_a_complete_exchange(self):
        report = valid_report()
        report['calls'][2]['request']['id'] = report['calls'][1]['request']['id']
        report['calls'][2]['response']['id'] = report['calls'][1]['response']['id']
        self.assertFalse(evaluate(report)['passed'])

    def test_private_scope_marker_does_not_leak_in_error(self):
        report = valid_report()
        report['calls'][9]['response']['result']['content'][0]['text'] += ' PRIVATE_ERROR_MARKER'
        self.assertFalse(evaluate(report)['passed'])


if __name__ == '__main__':
    unittest.main()
