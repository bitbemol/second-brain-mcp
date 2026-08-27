#!/usr/bin/env python3
"""Native real-stdio workflow; generated fixtures, fixed premeasurement gates, no new runtime dependencies."""
import argparse
import base64
import contextlib
import ctypes
import fcntl
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import signal
import stat
import tempfile
import threading
import time

from jsonschema import Draft202012Validator
from mcp_stdio import (RPC, artifact_root, owned, support_candidates, structured, save,
                       require_unoptimized, close_owned_client, cleanup_fixture)
from native_fixtures import MIB, png_bytes, png_dimensions, write_pdf
from tool_workflow import discover, digest, git_bytes, ERROR_SCHEMA

CASES = ('ordinary', 'metadata32', 'metadata256', 'metadata512', 'search256',
         'expansion', 'queue', 'cancel', 'disconnect')
GATES = {
    'ordinary_rss_bytes': 256 * MIB, 'source_rss_multiplier': 2,
    'source_rss_allowance': 256 * MIB, 'search256_rss_bytes': 768 * MIB,
    'queued_combined_growth_bytes': 64 * MIB, 'metadata32_ms': 1500,
    'metadata256_ms': 6000, 'metadata512_ms': 12000, 'search256_ms': 12000,
    'ordinary_ms': 5000, 'expansion_ms': 12000, 'queued_recovery_ms': 2000,
    'active_cancel_ms': 5000, 'disconnect_ms': 5000, 'watchdog_s': 45,
}
ROOT = None


class RUsageV0(ctypes.Structure):
    # Matches macOS SDK sys/resource.h, struct rusage_info_v0 (96 bytes).
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        'user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins',
        'wired_size', 'resident_size', 'phys_footprint', 'proc_start_abstime', 'proc_exit_abstime')]


def current_rss(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    function = library.proc_pid_rusage
    function.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_void_p)
    function.restype = ctypes.c_int
    value = RUsageV0()
    if function(pid, 0, ctypes.byref(value)) != 0:
        raise OSError(ctypes.get_errno(), 'proc_pid_rusage failed')
    return value.resident_size


class RSSGuard:
    """Sampled live safety guard; wait4 remains the authoritative process peak."""
    def __init__(self, clients, total_limit):
        self.clients, self.limit = clients, total_limit
        self.stop = threading.Event()
        self.error = None
        self.peak = 0
        self.peak_each = [0] * len(clients)
        self.samples = 0
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stop.is_set():
            try:
                values = [current_rss(client.p.pid) for client in self.clients]
                total = sum(values)
                self.peak_each = [max(previous, value) for previous, value in zip(self.peak_each, values)]
                self.peak = max(self.peak, total)
                self.samples += 1
                if total > self.limit:
                    self.error = f'Sampled RSS {total} exceeds frozen limit {self.limit}'
                    for client in self.clients:
                        os.killpg(client.p.pid, signal.SIGTERM)
                    return
            except BaseException as error:
                if not self.stop.is_set():
                    self.error = repr(error)
                return
            self.stop.wait(.02)

    def close(self):
        self.stop.set()
        self.thread.join(1)
        assert not self.thread.is_alive(), 'RSS sampler did not stop'
        return {'sampled_peak_combined_rss_bytes': self.peak,
                'sampled_peak_each_rss_bytes': self.peak_each, 'samples': self.samples,
                'interval_ms': 20, 'limit_bytes': self.limit, 'error': self.error}


def compact_row(row):
    """Retain content hashes/counts instead of large base64 fixtures in JSON evidence."""
    for item in row.get('response', {}).get('result', {}).get('content', []):
        if item.get('type') == 'image' and 'data' in item:
            raw = base64.b64decode(item.pop('data'), validate=True)
            item['verified_data_bytes'] = len(raw)
            item['verified_data_sha256'] = hashlib.sha256(raw).hexdigest()
            item['verified_dimensions'] = list(png_dimensions(raw))
        elif item.get('type') == 'text' and len(item.get('text', '').encode()) > 4096:
            raw = item.pop('text').encode()
            item['verified_text_bytes'] = len(raw)
            item['verified_text_sha256'] = hashlib.sha256(raw).hexdigest()


def invoke(client, tools, rows, name, arguments, limit_ms=5000, expect_error=False):
    if not expect_error:
        Draft202012Validator(tools[name]['inputSchema']).validate(arguments)
    row = client.wait(client.call(name, arguments))
    row.update(tool=name, arguments=arguments, latency_limit_ms=limit_ms)
    rows.append(row)
    assert row['elapsed_ms'] <= limit_ms, row
    if expect_error:
        assert not row['success'], row
        Draft202012Validator(ERROR_SCHEMA).validate(row['response']['result'])
        return row, None
    value = structured(row)
    Draft202012Validator(tools[name]['outputSchema']).validate(value)
    row['input_and_output_schema_valid'] = True
    return row, value


def require_metadata(row, value, expected_bytes, page_count=3):
    metadata = value['metadata']
    assert metadata['format'] == 'pdf' and metadata['byte_count'] == expected_bytes
    assert metadata['title'] == 'Native fixture title'
    assert metadata['author'] == 'Synthetic fixture'
    assert metadata['page_count'] == page_count and metadata['incomplete_fields'] == []
    content = row['response']['result']['content']
    assert len(content) == 1 and content[0]['type'] == 'text'
    decoded = json.loads(content[0]['text'])
    assert decoded == metadata, 'Text and structured metadata projections differ'
    assert not any(key in decoded for key in ('text', 'body', 'images'))


def require_images(row, count, expected_size=None):
    images = [item for item in row['response']['result']['content'] if item['type'] == 'image']
    assert len(images) == count
    for image in images:
        assert image['mimeType'] == 'image/png'
        raw = base64.b64decode(image['data'], validate=True)
        width, height = png_dimensions(raw)
        assert 0 < width <= 2000 and 0 < height <= 2000
        if expected_size:
            assert (width, height) == expected_size


def initialize(client, result, label):
    result[label + '_initialize'] = client.initialize()
    tools, result[label + '_discovery'] = discover(client)
    return tools


def link_fixture(master, vault, relative):
    destination = vault / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    os.link(master, destination)


@contextlib.contextmanager
def fixture(result):
    vault = owned(Path(tempfile.mkdtemp(prefix='native-vault-', dir=ROOT)))
    identity = vault.lstat()
    support = support_candidates(vault)
    assert not any(path.exists() or path.is_symlink() for path in support)
    (vault / 'notes').mkdir()
    (vault / 'references').mkdir()
    clients = []
    try:
        yield vault, support, clients
    except BaseException as error:
        result['primary_error'] = repr(error)
        raise
    finally:
        all_reaped = True
        for index, client in enumerate(clients):
            if client is not None:
                all_reaped = close_owned_client(client, result, f'exit_{index}') and all_reaped
        if all_reaped:
            cleanup_fixture(vault, identity, support, result)
        else:
            result['cleanup_skipped'] = 'A child was not reaped; fixture retained'
        if result.get('shutdown_error') or result.get('cleanup_errors'):
            raise RuntimeError('Native workflow shutdown or cleanup failed')


def guarded_case(binary, case, assets, result):
    limit = GATES['ordinary_rss_bytes']
    if case.startswith('metadata'):
        size = int(case.removeprefix('metadata')) * MIB
        limit = size * 2 + GATES['source_rss_allowance']
    elif case == 'search256':
        limit = GATES['search256_rss_bytes']
    guard = None
    with fixture(result) as (vault, support, clients):
        master = assets[case] if case in assets else assets['ordinary']
        link_fixture(master['path'], vault, 'references/ordinary.pdf')
        if case in ('cancel', 'disconnect'):
            link_fixture(assets['ocr']['path'], vault, 'references/active/ocr.pdf')
            (vault / 'notes/restart.md').write_text('restartneedle\n')
        client = RPC(binary, vault, case != 'ordinary')
        clients.append(client)
        tools = initialize(client, result, 'primary')
        guard = RSSGuard([client], limit)
        try:
            rows = result.setdefault('calls', [])
            if case.startswith('metadata'):
                for mode in ('first', 'warm'):
                    row, value = invoke(client, tools, rows, 'read_file', {
                        'format': 'pdf', 'path': 'references/ordinary.pdf', 'view': 'metadata'},
                        GATES[case + '_ms'])
                    row['mode'] = mode
                    require_metadata(row, value, master['bytes'])
            elif case in ('search256', 'expansion'):
                query = 'expansionneedle' if case == 'expansion' else 'nativegamma'
                for mode in ('first', 'warm'):
                    row, value = invoke(client, tools, rows, 'search_vault',
                        {'location': 'references', 'formats': ['pdf'], 'query': query},
                        GATES[case + '_ms'])
                    row['mode'] = mode
                    page = 1 if case == 'expansion' else 3
                    assert value == {'results': [{'path': 'references/ordinary.pdf', 'format': 'pdf', 'page': page}],
                                     'coverage': {'complete': True}}
                if case == 'expansion':
                    row, value = invoke(client, tools, rows, 'read_file',
                        {'format': 'pdf', 'path': 'references/ordinary.pdf', 'page': 1}, GATES['expansion_ms'])
                    require_images(row, 1)
                    texts = [item['text'] for item in row['response']['result']['content'] if item['type'] == 'text']
                    assert len(texts) == 1 and 'expansionneedle' in texts[0]
                    result['observed_native_display_text_bytes'] = len(texts[0].encode())
            elif case == 'ordinary':
                ordinary_workflow(client, tools, rows, vault, master, assets['png']['path'])
                result['first_process_rss_guard'] = guard.close()
                guard = None
                before = {str(path.relative_to(vault)): path.read_bytes() for path in vault.rglob('*') if path.is_file()}
                assert close_owned_client(client, result, 'writable_exit')
                clients[0] = None
                client = RPC(binary, vault, True)
                clients.append(client)
                tools = initialize(client, result, 'readonly')
                guard = RSSGuard([client], limit)
                assert set(tools) == {'read_file', 'search_vault', 'list_files', 'query_links'}
                row, value = invoke(client, tools, rows, 'read_file',
                    {'format': 'pdf', 'path': 'references/ordinary.pdf', 'view': 'metadata'})
                require_metadata(row, value, master['bytes'])
                row, value = invoke(client, tools, rows, 'read_file', {'format': 'png', 'path': 'notes/imported.png', 'render': True})
                require_images(row, 1, (32, 24))
                invoke(client, tools, rows, 'create_file',
                    {'format': 'png', 'path': 'notes/forbidden.png', 'source': str(assets['png']['path'])}, expect_error=True)
                after = {str(path.relative_to(vault)): path.read_bytes() for path in vault.rglob('*') if path.is_file()}
                assert before == after
                result['readonly_restart_unchanged'] = True
            else:
                active_lifecycle(client, tools, rows, vault, support, assets['ocr'], case, result)
                if case == 'disconnect':
                    result['active_rss_guard'] = guard.close()
                    guard = None
                    started = time.perf_counter()
                    assert close_owned_client(client, result, 'active_disconnect_exit')
                    result['disconnect_ms'] = (time.perf_counter() - started) * 1000
                    clients[0] = None
                    assert result['disconnect_ms'] <= GATES['disconnect_ms']
                    client = RPC(binary, vault, True)
                    clients.append(client)
                    tools = initialize(client, result, 'restart')
                    guard = RSSGuard([client], limit)
                    row, value = invoke(client, tools, rows, 'read_file',
                        {'format': 'pdf', 'path': 'references/ordinary.pdf', 'view': 'metadata'})
                    require_metadata(row, value, master['bytes'])
                    row, value = invoke(client, tools, rows, 'search_vault',
                        {'location': 'notes', 'query': 'restartneedle'})
                    assert value == {'results': [{'path': 'notes/restart.md', 'format': 'markdown'}],
                                     'coverage': {'complete': True}}
                    assert not (existing_support(support) / 'search-capture/active').exists()
                    result['restart_after_active_disconnect_works'] = True
                    result['restart_search_cleans_abandoned_capture'] = True
        finally:
            if guard is not None:
                result['rss_guard'] = guard.close()
    guards = [value for key, value in result.items() if 'rss_guard' in key]
    assert all(not value['error'] for value in guards), guards
    exits = [value for key, value in result.items() if key.startswith('exit_') or key.endswith('_exit')]
    assert all(value['peak_rss_bytes'] <= limit for value in exits), exits
    result['rss_limit_bytes'] = limit


def ordinary_workflow(client, tools, rows, vault, master, external):
    row, value = invoke(client, tools, rows, 'read_file',
        {'format': 'pdf', 'path': 'references/ordinary.pdf', 'view': 'metadata'})
    require_metadata(row, value, master['bytes'])
    row, value = invoke(client, tools, rows, 'read_file',
        {'format': 'pdf', 'path': 'references/ordinary.pdf', 'pages': [1, 2, 3]})
    require_images(row, 3)
    texts = [item['text'] for item in row['response']['result']['content'] if item['type'] == 'text']
    assert len(texts) == 3
    for index, marker in enumerate(('nativealpha', 'nativebeta', 'nativegamma'), 1):
        assert texts[index - 1].startswith(f'--- PDF Page {index} ---') and marker in texts[index - 1]
    row, value = invoke(client, tools, rows, 'create_file',
        {'format': 'png', 'path': 'notes/imported.png', 'source': str(external)})
    stored = (vault / 'notes/imported.png').read_bytes()
    assert png_dimensions(stored) == (32, 24)
    assert value['revision'] == digest(stored) and git_bytes(vault, 'notes/imported.png') == stored
    row, value = invoke(client, tools, rows, 'read_file', {'format': 'png', 'path': 'notes/imported.png', 'render': True})
    require_images(row, 1, (32, 24))
    assert value['revision'] == digest(stored)
    assert external.read_bytes() == png_bytes(), 'External import source was modified'


def existing_support(support):
    values = [path for path in support if path.is_dir() and not path.is_symlink()]
    assert len(values) == 1, 'Expected exactly one owned canonical support root'
    return values[0]


def active_lifecycle(client, tools, rows, vault, support, ocr, case, result):
    ticket = client.call('search_vault', {'location': 'references', 'directory': 'active',
                                       'formats': ['pdf'], 'query': 'HELLO'})
    capture = existing_support(support) / 'search-capture/active/00000000.capture'
    deadline = time.perf_counter() + 5
    observed = False
    while time.perf_counter() < deadline and not client.done(ticket):
        if capture.is_file() and capture.stat().st_size == ocr['bytes']:
            observed = True
            break
        time.sleep(.005)
    time.sleep(.1)
    assert observed and not client.done(ticket), 'Active native search was not observed; no cancellation claim'
    result['native_active_capture_observed'] = True
    if case == 'cancel':
        started = time.perf_counter()
        client.begin('notifications/cancelled', {'requestId': ticket.id, 'reason': 'native verification'}, notification=True)
        row, value = invoke(client, tools, rows, 'read_file',
            {'format': 'pdf', 'path': 'references/ordinary.pdf', 'view': 'metadata'},
            GATES['active_cancel_ms'])
        result['cancel_to_successor_ms'] = (time.perf_counter() - started) * 1000
        assert result['cancel_to_successor_ms'] <= GATES['active_cancel_ms']
        assert not client.done(ticket), 'Cancelled request emitted a response'
        result['cancelled_request_id'] = ticket.id


def queued_admission(binary, assets, result):
    with fixture(result) as (vault, support, clients):
        link_fixture(assets['ordinary']['path'], vault, 'references/ordinary.pdf')
        link_fixture(assets['metadata512']['path'], vault, 'references/large.pdf')
        tools = []
        rows = result.setdefault('calls', [])
        for index in range(2):
            client = RPC(binary, vault, True)
            clients.append(client)
            tools.append(initialize(client, result, f'process{index}'))
            row, value = invoke(client, tools[-1], rows, 'read_file',
                {'format': 'pdf', 'path': 'references/ordinary.pdf', 'view': 'metadata'})
            require_metadata(row, value, assets['ordinary']['bytes'])
        lock_path = existing_support(support) / 'locks/pdf-reference-reads.lock'
        descriptor = os.open(lock_path, os.O_RDWR | os.O_NOFOLLOW)
        guard = None
        try:
            metadata = os.fstat(descriptor)
            assert stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid()
            fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            baseline = [current_rss(client.p.pid) for client in clients]
            result['queued_baseline_rss_bytes'] = baseline
            guard = RSSGuard(clients, sum(baseline) + GATES['queued_combined_growth_bytes'])
            blockers = [client.call('read_file', {'format': 'pdf', 'path': 'references/ordinary.pdf', 'view': 'metadata'})
                        for client in clients]
            pending = [(clients[0], clients[0].call('read_file', {
                'format': 'pdf', 'path': 'references/large.pdf', 'view': 'metadata'})),
                       (clients[0], clients[0].call('read_file', {
                'format': 'pdf', 'path': 'references/large.pdf', 'page': 1})),
                       (clients[1], clients[1].call('read_file', {
                'format': 'pdf', 'path': 'references/large.pdf', 'view': 'metadata'}))]
            for client in clients:
                ping = client.wait(client.begin('ping', {}), timeout=2)
                assert ping['success']
            time.sleep(.25)
            assert all(not client.done(ticket) for client, ticket in zip(clients, blockers))
            assert all(not client.done(ticket) for client, ticket in pending)
            for client, ticket in pending:
                client.begin('notifications/cancelled', {'requestId': ticket.id, 'reason': 'queued native verification'}, notification=True)
            for client in clients:
                assert client.wait(client.begin('ping', {}), timeout=2)['success']
            result['queued_rss_guard'] = guard.close()
            guard = None
            assert not result['queued_rss_guard']['error']
            started = time.perf_counter()
            fcntl.lockf(descriptor, fcntl.LOCK_UN)
            for client, ticket in zip(clients, blockers):
                row = client.wait(ticket, timeout=2)
                require_metadata(row, structured(row), assets['ordinary']['bytes'])
                rows.append(row)
            for client, toolset in zip(clients, tools):
                row, value = invoke(client, toolset, rows, 'read_file',
                    {'format': 'pdf', 'path': 'references/ordinary.pdf', 'view': 'metadata'}, 2000)
                require_metadata(row, value, assets['ordinary']['bytes'])
            result['unlock_to_all_recovered_ms'] = (time.perf_counter() - started) * 1000
            assert result['unlock_to_all_recovered_ms'] <= GATES['queued_recovery_ms']
            assert all(not client.done(ticket) for client, ticket in pending)
            result['three_large_queued_requests_cancelled_without_response'] = True
        finally:
            if guard is not None:
                result['queued_rss_guard'] = guard.close()
            os.close(descriptor)
    assert all(result[f'exit_{index}']['peak_rss_bytes'] <= 256 * MIB for index in range(2))


def assets_for(cases):
    directory = owned(ROOT / 'generated')
    directory.mkdir()
    assets = {}
    specifications = {'ordinary': {}, 'expansion': {'pages': ('expansion',), 'expansion': True},
                      'ocr': {'ocr_pages': 64}}
    needed = {'ordinary', 'png'} | set(cases)
    if 'queue' in cases:
        needed.add('metadata512')
    if 'cancel' in cases or 'disconnect' in cases:
        needed.add('ocr')
    for size in (32, 256, 512):
        specifications['metadata' + str(size)] = {'target_bytes': size * MIB}
    specifications['search256'] = {'target_bytes': 256 * MIB}
    for name, arguments in specifications.items():
        if name in needed:
            if name == 'search256' and 'metadata256' in assets:
                assets[name] = dict(assets['metadata256'])
                continue
            path = owned(directory / (name + '.pdf'))
            assets[name] = write_pdf(path, **arguments)
            assets[name]['path'] = path
    path = owned(directory / 'external.png')
    raw = png_bytes()
    path.write_bytes(raw)
    assets['png'] = {'path': path, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'dimensions': [32, 24]}
    return assets


def main():
    global ROOT
    require_unoptimized()
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--sha', required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--samples', type=int, default=1)
    parser.add_argument('--cases', nargs='+', choices=CASES, default=list(CASES))
    args = parser.parse_args()
    if not 1 <= args.samples <= 100:
        parser.error('--samples must be1..100;30 minimum for p95 claims')
    if len(set(args.cases)) != len(args.cases):
        parser.error('--cases must contain unique workload names')
    binary = args.binary.resolve(strict=True)
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == args.sha
    ROOT = artifact_root(args.output)
    report = {'binary': str(binary), 'sha256': args.sha, 'gates': GATES,
              'schema_validator': 'jsonschema' + importlib.metadata.version('jsonschema') + '/Draft202012',
              'sampling': '20ms libproc live guard; wait4 peak authoritative; OS cache uncontrolled',
              'samples_requested': args.samples, 'cases_requested': args.cases,
              'expected_case_index_grid': [{'index': index, 'case': case}
                                           for index in range(args.samples) for case in args.cases],
              'complete_and_correct': False, 'samples': []}
    output = ROOT / 'native-workflow.json'
    try:
        assets = assets_for(args.cases)
        report['fixtures'] = {name: {key: str(value) if isinstance(value, Path) else value for key, value in item.items()}
                              for name, item in assets.items()}
        save(output, report)
        for index in range(args.samples):
            for case in args.cases:
                row = {'index': index, 'case': case}
                report['samples'].append(row)
                try:
                    if case == 'queue':
                        queued_admission(binary, assets, row)
                    else:
                        guarded_case(binary, case, assets, row)
                    row['all_checks_passed'] = True
                except BaseException as error:
                    row['all_checks_passed'] = False
                    row.setdefault('primary_error', repr(error))
                    raise
                finally:
                    for call in row.get('calls', []):
                        try:
                            compact_row(call)
                        except BaseException as error:
                            row.setdefault('artifact_compaction_errors', []).append(repr(error))
                            row['all_checks_passed'] = False
                    save(output, report)
                if row.get('artifact_compaction_errors'):
                    raise RuntimeError('Artifact compaction failed; evidence is not complete')
                print(json.dumps({'case': case, 'sample': index, 'all_checks_passed': True}), flush=True)
        observed = [{'index': row['index'], 'case': row['case']} for row in report['samples']]
        report['complete_and_correct'] = (
            bool(report['expected_case_index_grid'])
            and observed == report['expected_case_index_grid']
            and all(row.get('all_checks_passed') is True for row in report['samples'])
        )
        if not report['complete_and_correct']:
            raise RuntimeError('Requested native workload grid was not completed correctly')
        save(output, report)
    except BaseException as error:
        report['complete_and_correct'] = False
        report['error'] = repr(error)
        save(output, report)
        raise


if __name__ == '__main__':
    main()
