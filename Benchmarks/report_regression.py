#!/usr/bin/env python3
"""Bounded report replay; raw protocol evidence, not schema or performance validation."""
import argparse
import base64
import hashlib
import io
import json
import math
from pathlib import Path
import tempfile

from PIL import Image
from mcp_stdio import (RPC, artifact_root, owned, support_candidates, save,
                       require_unoptimized, close_owned_client, cleanup_fixture)
from native_fixtures import png_bytes

CANVAS = '{"nodes":[],"edges":[]}'
REPLACEMENT = '{"nodes":[{"id":"one","type":"text","text":"updated","x":0,"y":0,"width":100,"height":50}],"edges":[]}'
SOURCE = '{"value":1}'
MARKDOWN = '---\ntitle: Unrelated\ntags: [qa]\n---\nPRIVATE_BODY_MARKER needle\n'
STALE = 'sha256:' + '0' * 64
CASE_IDS = (
    'setup_create', 'malformed_har', 'repeated_separator', 'canvas_append', 'canvas_replace',
    'stale_update', 'stale_move', 'placeholder_move', 'env_move', 'missing_scope',
    'broad_coverage', 'metadata_coverage', 'render_png',
    'png_list', 'png_search', 'png_metadata', 'render_gif',
    'gif_list', 'gif_search', 'gif_metadata', 'gif_list_repeat', 'gif_search_repeat',
)
ERRORS = {
    'malformed_har': ('INVALID_REQUEST', 'not_applied', 'har'),
    'repeated_separator': ('INVALID_PATH', 'not_applied', 'empty path component'),
    'canvas_append': ('INVALID_REQUEST', 'not_applied', 'append'),
    'stale_update': ('REVISION_CONFLICT', 'not_applied', 'changed'),
    'stale_move': ('REVISION_CONFLICT', 'not_applied', 'changed'),
    'env_move': ('OPERATION_FAILED', 'not_applied', 'hidden'),
    'missing_scope': ('DIRECTORY_NOT_FOUND', 'read_only', 'directory not found'),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    return digest(path.read_bytes()) if path.is_file() else None


def initialize_params():
    return {'protocolVersion': '2025-06-18', 'capabilities': {},
            'clientInfo': {'name': 'second-brain-report-replay', 'version': '1'}}


def expected_call(case):
    """Independent frozen workload oracle, never derived from a recorded request."""
    calls = {
        'setup_create': ('create_file', {'format': 'json', 'path': 'notes/ready.json', 'content': '{}'}),
        'malformed_har': ('create_file', {'format': 'har', 'path': 'notes/invalid.har', 'content': '{}'}),
        'repeated_separator': ('create_file', {'format': 'json', 'path': 'notes//invalid.json', 'content': '{}'}),
        'canvas_append': ('update_file', {'format': 'canvas', 'path': 'notes/map.canvas', 'content': CANVAS,
                            'mode': 'append', 'expected_revision': 'sha256:' + digest(CANVAS.encode())}),
        'canvas_replace': ('update_file', {'format': 'canvas', 'path': 'notes/map.canvas', 'content': REPLACEMENT,
                             'mode': 'replace', 'expected_revision': 'sha256:' + digest(CANVAS.encode())}),
        'stale_update': ('update_file', {'format': 'json', 'path': 'notes/source.json',
                           'mode': 'replace', 'content': '{}', 'expected_revision': STALE}),
        'stale_move': ('move_path', {'kind': 'file', 'format': 'json',
                         'source_path': 'notes/source.json', 'destination_path': 'notes/moved.json',
                         'expected_revision': STALE}),
        'placeholder_move': ('move_path', {'kind': 'directory', 'source_path': 'notes/ticket',
                               'destination_path': 'notes/completed/ticket'}),
        'env_move': ('move_path', {'kind': 'directory', 'source_path': 'notes/blocked',
                       'destination_path': 'notes/completed/blocked'}),
        'missing_scope': ('search_vault', {'location': 'notes',
                            'directory': 'PRIVATE_ERROR_MARKER/missing', 'query': 'needle'}),
        'broad_coverage': ('search_vault', {'location': 'notes', 'directory': 'coverage',
                            'query': 'absent', 'formats': ['markdown', 'har']}),
        'metadata_coverage': ('search_vault', {'location': 'notes', 'directory': 'metadata', 'tags': ['qa']}),
    }
    for format_name in ('png', 'gif'):
        calls['render_' + format_name] = ('read_file', {
            'format': format_name, 'path': 'notes/image.' + format_name, 'render': True})
        calls[format_name + '_list'] = ('list_files', {'area': 'notes', 'limit': 10})
        calls[format_name + '_search'] = ('search_vault', {
            'location': 'notes', 'query': 'needle', 'formats': ['markdown']})
        calls[format_name + '_metadata'] = ('read_file', {
            'format': 'markdown', 'path': 'notes/unrelated.md', 'view': 'metadata'})
    calls['gif_list_repeat'] = calls['gif_list']
    calls['gif_search_repeat'] = calls['gif_search']
    name, arguments = calls[case]
    return {'name': name, 'arguments': arguments}


def exact_json(value):
    # Python dictionary equality conflates JSON true with numeric 1.
    return json.dumps(value, sort_keys=True, allow_nan=False)


def result(row):
    assert row['response']['id'] == row['request']['id']
    assert row['response']['jsonrpc'] == '2.0' and 'error' not in row['response']
    assert type(row['elapsed_ms']) in (int, float) and math.isfinite(row['elapsed_ms'])
    assert 0 <= row['elapsed_ms'] <= 45000
    for key in ('request_bytes', 'response_bytes'):
        assert type(row[key]) is int and row[key] > 0
    return row['response']['result']


def check_case(row):
    name = row['case']
    assert exact_json(row['request']) == exact_json({
        'jsonrpc': '2.0', 'id': row['request']['id'],
        'method': 'tools/call', 'params': expected_call(name)})
    body = result(row)
    blocks = body['content']
    text = '\n'.join(block['text'] for block in blocks if block['type'] == 'text')
    assert blocks and all(block['type'] in ('text', 'image') for block in blocks)
    if name in ERRORS:
        code, state, detail = ERRORS[name]
        assert row['success'] is False and body['isError'] is True
        assert body['structuredContent']['error'] == {
            'code': code, 'state': state, 'retry': 'correct_request'}
        assert detail in text.lower()
        assert len(text.encode()) <= 1024 and '/private/' not in text and '/Users/' not in text
        assert 'PRIVATE_ERROR_MARKER' not in text
        if name == 'repeated_separator':
            assert 'symbolic' not in text.lower()
        if name == 'canvas_append':
            assert 'replace' in text.lower()
    else:
        assert row['success'] is True and body.get('isError') is not True

    expected_files = {
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
    if name in expected_files:
        assert row['files'] == expected_files[name]
    if name == 'canvas_replace':
        assert body['structuredContent']['revision'] == 'sha256:' + digest(REPLACEMENT.encode())
    if name in ('broad_coverage', 'metadata_coverage'):
        coverage = body['structuredContent']['coverage']
        assert body['structuredContent']['results'] == []
        assert coverage['complete'] is False and coverage['failed_files'] == 1
        if name == 'broad_coverage':
            assert coverage['failed_by_format'] == {'har': 1}
            assert coverage['complete_formats'] == ['markdown']
        else:
            assert coverage['failed_by_format'] == {'markdown': 1}
            assert coverage['complete_formats'] == []
    images = [block for block in blocks if block['type'] == 'image']
    if name.startswith('render_'):
        format_name = name.removeprefix('render_')
        assert len(images) == (1 if format_name == 'png' else 8)
        for index, image in enumerate(images):
            assert image['mimeType'] == 'image/png'
            with Image.open(io.BytesIO(base64.b64decode(image['data'], validate=True))) as decoded:
                assert decoded.format == 'PNG' and decoded.size == (64, 48)
                decoded.load()
                pixels = decoded.convert('RGB')
                if format_name == 'png':
                    with Image.open(io.BytesIO(png_bytes(64, 48))) as original:
                        assert pixels.tobytes() == original.convert('RGB').tobytes()
                else:
                    source_index = (0, 3, 5, 8, 11, 14, 16, 19)[index]
                    expected = (source_index * 11, 120, 255 - source_index * 11)
                    assert all(abs(lo - value) <= 1 and abs(hi - value) <= 1
                               for (lo, hi), value in zip(pixels.getextrema(), expected))
    else:
        assert not images
    if name.startswith(('png_', 'gif_')):
        assert 'PRIVATE_BODY_MARKER' not in text
        if '_search' in name:
            assert body['structuredContent']['results'] == [
                {'path': 'notes/unrelated.md', 'format': 'markdown'}]
        if name.endswith('_metadata'):
            assert body['structuredContent']['revision'] == 'sha256:' + digest(MARKDOWN.encode())


def evaluate(report):
    errors = []
    rows = report.get('calls')
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        return {'passed': False, 'errors': ['Malformed raw grid']}
    try:
        assert [row['case'] for row in rows] == list(CASE_IDS)
        assert report['execution_complete'] is True and not report.get('error')
        assert report['binary_sha256'] == report['verified_binary_sha256']
        assert len(report['binary_sha256']) == 64
        assert report['initialize']['success'] is True
        initialized = report['initialize']['response']
        assert initialized['jsonrpc'] == '2.0' and 'error' not in initialized
        assert isinstance(initialized['result'], dict)
        initialization_request = report['initialize']['request']
        assert exact_json(initialization_request) == exact_json({
            'jsonrpc': '2.0', 'id': initialized['id'],
            'method': 'initialize', 'params': initialize_params()})
        identifiers = [initialized['id']] + [row['request']['id'] for row in rows]
        assert all(type(identifier) is int and identifier > 0 for identifier in identifiers)
        assert len(set(identifiers)) == len(identifiers)
        assert report['exit']['exit_code'] == 0 and report['exit']['forced_signals'] == 0
        assert not any(report.get(key) for key in ('shutdown_error', 'cleanup_errors', 'cleanup_skipped'))
        assert report['cleanup_verified_absent'] is True
        assert {'removed_owned_directory': report['vault']} in report['cleanup']
        assert report['readonly_files_before'] == report['readonly_files_after']
        assert report['readonly_files_before']
        for prefix in ('png', 'gif'):
            group = [row for row in rows if row['case'].startswith(prefix + '_')]
            assert len(group) == (3 if prefix == 'png' else 5)
            # All three requests are sent before any are awaited (recorded by runner).
            assert len({row['concurrent_batch'] for row in group}) == 1
    except (AssertionError, KeyError, TypeError, ValueError, AttributeError):
        errors.append('Invalid identity, exact grid, lifecycle, or unchanged read-only fixtures')
    for row in rows:
        try:
            check_case(row)
        except (AssertionError, KeyError, TypeError, ValueError, AttributeError, OSError):
            errors.append(row.get('case', 'unknown'))
    return {'passed': not errors, 'errors': errors, 'recorded_calls': len(rows),
            'schema_validation': 'not_run', 'performance_claim': 'none'}


def fixture(vault):
    (vault / 'notes').mkdir()
    (vault / 'references').mkdir()
    for name, content in [('source.json', SOURCE), ('map.canvas', CANVAS), ('unrelated.md', MARKDOWN)]:
        (vault / 'notes' / name).write_text(content)
    (vault / 'notes/image.png').write_bytes(png_bytes(64, 48))
    frames = [Image.new('RGB', (64, 48), (index * 11, 120, 255 - index * 11))
              for index in range(20)]
    frames[0].save(vault / 'notes/image.gif', format='GIF', save_all=True,
                   append_images=frames[1:], duration=100, loop=0, optimize=False)


def replay(binary, expected_sha, root):
    vault = owned(Path(tempfile.mkdtemp(prefix='report-replay-', dir=root)))
    identity = vault.lstat()
    support = support_candidates(vault)
    report = {'binary_sha256': expected_sha, 'verified_binary_sha256': digest(binary.read_bytes()),
              'vault': str(vault), 'calls': [], 'execution_complete': False,
              'scope': 'Report correctness replay; no schema validation or timing gate',
              'harness_sha256': digest(Path(__file__).read_bytes())}
    client = None
    owned_support = []
    reaped = True

    def begin(case, name, arguments):
        ticket = client.call(name, arguments)
        return case, ticket, {'jsonrpc': '2.0', 'id': ticket.id, 'method': 'tools/call',
                              'params': {'name': name, 'arguments': arguments}}

    def finish(pending, paths=(), batch=None):
        case, ticket, request = pending
        row = client.wait(ticket)
        row.update(case=case, request=request)
        if paths:
            row['files'] = {path: file_hash(vault / path) for path in paths}
        if batch is not None:
            row['concurrent_batch'] = batch
        report['calls'].append(row)
        save(root / 'report-regression.json', report)
        return row

    def call(case, name, arguments, paths=()):
        return finish(begin(case, name, arguments), paths)

    try:
        assert report['verified_binary_sha256'] == expected_sha
        assert not any(path.exists() or path.is_symlink() for path in support)
        owned_support = support
        fixture(vault)
        client = RPC(binary, vault, False)
        initialization = initialize_params()
        ticket = client.begin('initialize', initialization)
        report['initialize'] = client.wait(ticket)
        report['initialize']['request'] = {'jsonrpc': '2.0', 'id': ticket.id,
                                           'method': 'initialize', 'params': initialization}
        assert report['initialize']['success'] is True
        client.begin('notifications/initialized', {}, notification=True)
        call('setup_create', 'create_file', {'format': 'json', 'path': 'notes/ready.json', 'content': '{}'})
        call('malformed_har', 'create_file',
             {'format': 'har', 'path': 'notes/invalid.har', 'content': '{}'}, ['notes/invalid.har'])
        call('repeated_separator', 'create_file',
             {'format': 'json', 'path': 'notes//invalid.json', 'content': '{}'}, ['notes/invalid.json'])
        canvas_args = {'format': 'canvas', 'path': 'notes/map.canvas', 'content': CANVAS,
                       'mode': 'append', 'expected_revision': 'sha256:' + digest(CANVAS.encode())}
        call('canvas_append', 'update_file', canvas_args, ['notes/map.canvas'])
        call('canvas_replace', 'update_file', dict(canvas_args, mode='replace', content=REPLACEMENT),
             ['notes/map.canvas'])
        call('stale_update', 'update_file', {'format': 'json', 'path': 'notes/source.json',
             'mode': 'replace', 'content': '{}', 'expected_revision': STALE}, ['notes/source.json'])
        call('stale_move', 'move_path', {'kind': 'file', 'format': 'json',
             'source_path': 'notes/source.json', 'destination_path': 'notes/moved.json',
             'expected_revision': STALE}, ['notes/source.json', 'notes/moved.json'])
        placeholder = vault / 'notes/ticket/attachments/.gitkeep.md'
        placeholder.parent.mkdir(parents=True)
        placeholder.write_bytes(b'')
        call('placeholder_move', 'move_path', {'kind': 'directory',
             'source_path': 'notes/ticket', 'destination_path': 'notes/completed/ticket'},
             ['notes/ticket/attachments/.gitkeep.md', 'notes/completed/ticket/attachments/.gitkeep.md'])
        blocked = vault / 'notes/blocked/.env'
        blocked.parent.mkdir()
        blocked.write_bytes(b'fixture-only')
        call('env_move', 'move_path', {'kind': 'directory', 'source_path': 'notes/blocked',
             'destination_path': 'notes/completed/blocked'},
             ['notes/blocked/.env', 'notes/completed/blocked/.env'])

        # No later mutation: malformed/sparse discovery fixtures cannot poison a Git snapshot.
        coverage = vault / 'notes/coverage'
        coverage.mkdir()
        (coverage / 'healthy.md').write_text('healthy')
        with (coverage / 'oversized.har').open('xb') as handle:
            handle.truncate(25 * 1024 * 1024 + 1)
        metadata = vault / 'notes/metadata'
        metadata.mkdir()
        (metadata / 'invalid.md').write_bytes(b'\xff')
        (metadata / 'healthy.json').write_text('{}')
        observed = ['notes/source.json', 'notes/map.canvas', 'notes/unrelated.md',
                    'notes/image.png', 'notes/image.gif', 'notes/metadata/invalid.md',
                    'notes/metadata/healthy.json', 'notes/coverage/healthy.md']
        report['readonly_files_before'] = {path: file_hash(vault / path) for path in observed}
        call('missing_scope', 'search_vault',
             {'location': 'notes', 'directory': 'PRIVATE_ERROR_MARKER/missing', 'query': 'needle'})
        call('broad_coverage', 'search_vault',
             {'location': 'notes', 'directory': 'coverage', 'query': 'absent',
              'formats': ['markdown', 'har']})
        call('metadata_coverage', 'search_vault',
             {'location': 'notes', 'directory': 'metadata', 'tags': ['qa']})
        for format_name in ('png', 'gif'):
            call('render_' + format_name, 'read_file',
                 {'format': format_name, 'path': 'notes/image.' + format_name, 'render': True})
            pending = [
                begin(format_name + '_list', 'list_files', {'area': 'notes', 'limit': 10}),
                begin(format_name + '_search', 'search_vault',
                      {'location': 'notes', 'query': 'needle', 'formats': ['markdown']}),
                begin(format_name + '_metadata', 'read_file',
                      {'format': 'markdown', 'path': 'notes/unrelated.md', 'view': 'metadata'}),
            ]
            if format_name == 'gif':
                pending.extend([
                    begin('gif_list_repeat', 'list_files', {'area': 'notes', 'limit': 10}),
                    begin('gif_search_repeat', 'search_vault',
                          {'location': 'notes', 'query': 'needle', 'formats': ['markdown']}),
                ])
            for item in pending:
                finish(item, batch=format_name)
        report['readonly_files_after'] = {path: file_hash(vault / path) for path in observed}
        report['execution_complete'] = True
    except BaseException as error:
        report['error'] = repr(error)
    finally:
        if client is not None:
            reaped = close_owned_client(client, report, 'exit')
        if reaped:
            cleanup_fixture(vault, identity, owned_support, report)
            report['cleanup_verified_absent'] = not any(
                path.exists() or path.is_symlink() for path in [vault] + owned_support)
        else:
            report['cleanup_skipped'] = 'Child exit unconfirmed; fixture retained'
        report['analysis'] = evaluate(report)
        save(root / 'report-regression.json', report)
    return report


def main():
    require_unoptimized()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--sha', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    assert digest(binary.read_bytes()) == args.sha
    report = replay(binary, args.sha, artifact_root(args.output))
    print(json.dumps(report['analysis'], indent=2), flush=True)
    raise SystemExit(0 if report['analysis']['passed'] else 1)


if __name__ == '__main__':
    main()
