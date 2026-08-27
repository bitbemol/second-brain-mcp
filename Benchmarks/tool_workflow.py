#!/usr/bin/env python3
"""Real stdio eight-tool checks; synthetic vault, exact bytes/Git, full JSON Schema.

Uses disposable vaults beneath this evidence directory and their initially absent
Application Support hashes. No project dependency. Timings are write-start to
complete-frame arrival, including server work but excluding client JSON/schema
decoding and untimed Git verification. Baseline/candidate order alternates by pair.
"""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = None
from jsonschema import Draft202012Validator
from mcp_stdio import (RPC, owned, support_candidates, structured, save, artifact_root,
                       require_unoptimized, close_owned_client, cleanup_fixture)

ERROR_SCHEMA = {
    'type': 'object', 'required': ['content', 'isError'],
    'properties': {'isError': {'const': True}, 'content': {
        'type': 'array', 'minItems': 1, 'maxItems': 1,
        'items': {'type': 'object', 'required': ['type', 'text'],
                  'properties': {'type': {'const': 'text'}, 'text': {'type': 'string'}}}}}
}


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def git_bytes(vault, path):
    return subprocess.run(['/usr/bin/git', '-C', str(owned(vault)), 'show', 'HEAD:' + path],
                          check=True, capture_output=True, timeout=10).stdout


def discover(client):
    response = client.wait(client.begin('tools/list', {}))
    assert response['success'], response
    discovered = response['response']['result']['tools']
    tools = {tool['name']: tool for tool in discovered}
    assert len(discovered) == len(tools), 'Duplicate tool names'
    for tool in tools.values():
        Draft202012Validator.check_schema(tool['inputSchema'])
        assert 'outputSchema' in tool, 'Missing output schema'
        Draft202012Validator.check_schema(tool['outputSchema'])
    return tools, response


def invoke(client, tools, rows, name, args, label=None, expect_error=False):
    if not expect_error:
        Draft202012Validator(tools[name]['inputSchema']).validate(args)
    row = client.wait(client.call(name, args))
    row.update(tool=name, label=label or name, arguments=args)
    rows.append(row)
    if expect_error:
        assert not row['success'], row
        Draft202012Validator(ERROR_SCHEMA).validate(row['response']['result'])
        return row
    value = structured(row)
    if 'outputSchema' in tools[name]:
        Draft202012Validator(tools[name]['outputSchema']).validate(value)
    row['input_and_output_schema_valid'] = True
    return value


def verify_note(vault, path, value, expected):
    assert (vault / path).read_bytes() == expected
    assert value['revision'] == digest(expected)
    assert git_bytes(vault, path) == expected


def sample(binary, index, extra, result):
    vault = owned(Path(tempfile.mkdtemp(prefix='tool-workflow-', dir=ROOT)))
    identity = vault.lstat()
    support = support_candidates(vault)
    assert not any(p.exists() or p.is_symlink() for p in support)
    (vault / 'notes').mkdir()
    (vault / 'references').mkdir()
    (vault / 'notes/A.md').write_text('# A\n\nworkflowneedle [[B]] [[B]]\n')
    (vault / 'notes/B.md').write_text('# B\n\nDestination\n')
    client = None
    reaped = True
    failure = None
    result.update(sample=index, calls=[], readonly_calls=[])
    try:
        client = RPC(binary, vault, False)
        reaped = False
        result['initialize'] = client.initialize()
        tools, result['discovery'] = discover(client)
        assert set(tools) == {'create_file', 'read_file', 'update_file', 'delete_file',
                              'list_files', 'search_vault', 'query_links', 'move_path'}
        # Untimed barrier includes startup recovery and a successful Git snapshot.
        invoke(client, tools, [], 'create_file', {'format': 'json', 'path': 'notes/bootstrap.json', 'content': '{}'})
        overhead = len(json.dumps({'iteration': '00000000', 'padding': ''}, separators=(',', ':')).encode())
        expected = json.dumps({'iteration': '00000000', 'padding': 'a' * (1024 * 1024 - overhead)},
                              separators=(',', ':')).encode()
        assert len(expected) == 1024 * 1024
        rows = result['calls']
        path = 'notes/payload.json'
        created = invoke(client, tools, rows, 'create_file', {'format': 'json', 'path': path,
                                                           'content': expected.decode()})
        verify_note(vault, path, created, expected)
        read = invoke(client, tools, rows, 'read_file', {'format': 'json', 'path': path, 'max_bytes': 4096})
        assert read['revision'] == digest(expected)
        first = rows[-1]['response']['result']['content'][0]['text'].encode()
        assert first == expected[:4096]
        assert read['text_window'] == {'byte_offset': 0, 'byte_count': 4096,
                                      'total_bytes': len(expected), 'next_byte_offset': 4096}
        updated = invoke(client, tools, rows, 'update_file', {'format': 'json', 'path': path,
            'expected_revision': read['revision'], 'mode': 'patch',
            'replacements': [{'old_text': '00000000', 'new_text': '00000001'}]})
        expected = expected.replace(b'00000000', b'00000001')
        verify_note(vault, path, updated, expected)
        listing = invoke(client, tools, rows, 'list_files', {'area': 'notes', 'limit': 20})
        assert {item['path'] for item in listing['files']} == {
            'notes/A.md', 'notes/B.md', 'notes/bootstrap.json', path}
        search = invoke(client, tools, rows, 'search_vault', {'location': 'notes', 'query': 'workflowneedle'})
        assert [(item['path'], item['format']) for item in search['results']] == [('notes/A.md', 'markdown')]
        graph = invoke(client, tools, rows, 'query_links', {'direction': 'outgoing', 'target': 'notes/A.md'})
        assert len(graph['results']) == 2
        assert all(item['resolved_path'] == 'notes/B.md' for item in graph['results'])
        moved = invoke(client, tools, rows, 'move_path', {'kind': 'file', 'format': 'json',
            'source_path': path, 'destination_path': 'notes/moved.json', 'expected_revision': updated['revision']})
        assert moved == {'source_path': path, 'destination_path': 'notes/moved.json'}
        assert not (vault / path).exists()
        assert (vault / 'notes/moved.json').read_bytes() == expected
        assert git_bytes(vault, 'notes/moved.json') == expected
        invoke(client, tools, rows, 'delete_file', {'format': 'json', 'path': 'notes/moved.json',
                                                  'expected_revision': updated['revision']})
        assert not (vault / 'notes/moved.json').exists()
        trash = [p for p in (vault / '.trash').rglob('*') if p.is_file()]
        assert len(trash) == 1 and trash[0].read_bytes() == expected
        tracked = subprocess.run(['/usr/bin/git', '-C', str(vault), 'ls-tree', '-r', '--name-only', 'HEAD'],
                                 capture_output=True, check=True, timeout=10).stdout.decode().splitlines()
        assert 'notes/moved.json' not in tracked and path not in tracked
        result['exact_bytes_revisions_git_and_trash_verified'] = True
        if extra:
            exercise_candidate(client, tools, result, vault)
        reaped = close_owned_client(client, result, 'exit')
        client = None
        if result.get('shutdown_error'):
            raise RuntimeError(result['shutdown_error'])
        before = {str(p.relative_to(vault)): p.read_bytes() for p in vault.rglob('*') if p.is_file()}
        client = RPC(binary, vault, True)
        reaped = False
        result['readonly_initialize'] = client.initialize()
        readonly_tools, result['readonly_discovery'] = discover(client)
        assert set(readonly_tools) == {'read_file', 'search_vault', 'list_files', 'query_links'}
        invoke(client, readonly_tools, result['readonly_calls'], 'read_file',
               {'format': 'markdown', 'path': 'notes/B.md', 'view': 'metadata'})
        invoke(client, readonly_tools, result['readonly_calls'], 'create_file',
               {'format': 'json', 'path': 'notes/forbidden.json', 'content': '{}'}, expect_error=True)
        reaped = close_owned_client(client, result, 'readonly_exit')
        client = None
        if result.get('shutdown_error'):
            raise RuntimeError(result['shutdown_error'])
        after = {str(p.relative_to(vault)): p.read_bytes() for p in vault.rglob('*') if p.is_file()}
        assert before == after
        result['readonly_regular_file_paths_and_bytes_unchanged'] = True
    except BaseException as error:
        failure = error
        result['error'] = repr(error)
    finally:
        if client is not None:
            reaped = close_owned_client(client, result, 'exception_exit')
        if reaped:
            cleanup_fixture(vault, identity, support, result)
        else:
            result['cleanup_skipped'] = 'Child exit not confirmed; owned fixture retained'
    if failure is not None:
        raise failure
    if result.get('shutdown_error') or result.get('cleanup_errors'):
        raise RuntimeError('Benchmark shutdown or cleanup failed; see retained evidence')
    return result


def exercise_candidate(client, tools, result, vault):
    rows = result.setdefault('candidate_contract_calls', [])
    grouped = invoke(client, tools, rows, 'query_links', {'direction': 'backlinks', 'target': 'B'})
    assert grouped['coverage'] == {'complete': True}
    assert grouped['results'] == [{'source_path': 'notes/A.md', 'resolved_path': 'notes/B.md',
        'resolved_format': 'markdown', 'occurrence_count': 2, 'ambiguous': False}]
    detail = invoke(client, tools, rows, 'query_links', {'direction': 'backlinks', 'target': 'B',
        'group_by': 'occurrence', 'source_path': 'notes/A.md', 'limit': 1})
    assert len(detail['results']) == 1 and 'next_cursor' in detail
    next_page = invoke(client, tools, rows, 'query_links', {'direction': 'backlinks', 'target': 'B',
        'group_by': 'occurrence', 'source_path': 'notes/A.md', 'limit': 2, 'cursor': detail['next_cursor']})
    assert len(next_page['results']) == 1 and 'next_cursor' not in next_page
    metadata = invoke(client, tools, rows, 'read_file', {'format': 'markdown', 'path': 'notes/A.md', 'view': 'metadata'})
    assert metadata['metadata']['incomplete_fields'] == []
    (vault / 'notes/broken.md').write_bytes(b'\xff')
    incomplete = invoke(client, tools, rows, 'search_vault', {'location': 'notes', 'query': 'absentmarker'})
    assert incomplete['results'] == [] and incomplete['coverage']['complete'] is False
    assert incomplete['coverage']['failed_files'] == 1
    assert incomplete['coverage']['samples'] == [{'path': 'notes/broken.md', 'reason': 'invalid_document'}]
    assert incomplete['coverage']['samples_truncated'] is False
    invoke(client, tools, rows, 'search_vault', {'location': 'notes', 'query': 'x', 'cursor': 'invalid'}, expect_error=True)


def main():
    global ROOT
    require_unoptimized()
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, help='Fresh directory for evidence; defaults to a new temporary directory')
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--sha', required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--samples', type=int, default=30)
    parser.add_argument('--candidate-contracts', action='store_true')
    parser.add_argument('--comparison-binary', type=Path)
    parser.add_argument('--comparison-sha')
    args = parser.parse_args()
    if not 1 <= args.samples <= 100:
        parser.error('--samples must be between 1 and 100')
    args.binary = args.binary.resolve(strict=True)
    if args.comparison_binary:
        args.comparison_binary = args.comparison_binary.resolve(strict=True)
    ROOT = artifact_root(args.output)
    assert hashlib.sha256(args.binary.read_bytes()).hexdigest() == args.sha
    assert bool(args.comparison_binary) == bool(args.comparison_sha)
    if args.comparison_binary:
        assert hashlib.sha256(args.comparison_binary.read_bytes()).hexdigest() == args.comparison_sha
    assert args.label.replace('-', '').replace('_', '').isalnum()
    output = ROOT / (args.label + '.json')
    assert not output.exists(), 'Use a fresh label; evidence is not overwritten'
    report = {'binary': str(args.binary), 'sha256': args.sha, 'schema_validator': 'jsonschema' + importlib.metadata.version('jsonschema') + '/Draft202012',
              'fixture': '1MiB JSON mutation plus two Markdown link notes; fresh writable/readonly processes',
              'comparison_binary': str(args.comparison_binary) if args.comparison_binary else None,
              'comparison_sha256': args.comparison_sha, 'samples': []}
    for index in range(args.samples):
        variants = [('primary', args.binary, args.candidate_contracts and not args.comparison_binary)]
        if args.comparison_binary:
            variants.append(('comparison', args.comparison_binary, args.candidate_contracts))
        if index % 2:
            variants.reverse()
        for variant, binary, extra in variants:
            row = {'variant': variant, 'sample': index}
            report['samples'].append(row)
            try:
                sample(binary, index, extra, row)
                row['all_tools_correct'] = True
            except BaseException as error:
                row['all_tools_correct'] = False
                row['error'] = repr(error)
                raise
            finally:
                # Do not retain large mutation arguments; payload is deterministic above.
                for call in row.get('calls', []):
                    if 'content' in call.get('arguments', {}):
                        raw = call['arguments'].pop('content').encode()
                        call['input_content_bytes'] = len(raw)
                        call['input_content_sha256'] = hashlib.sha256(raw).hexdigest()
                save(output, report)
            print(json.dumps({'sample': index, 'variant': variant, 'all_tools_correct': True}), flush=True)


if __name__ == '__main__':
    main()
