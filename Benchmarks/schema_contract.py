#!/usr/bin/env python3
"""Negative schema contracts against actual stdio discovery; no project dependencies."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import tempfile

ROOT = None
from jsonschema import Draft202012Validator
from tool_workflow import discover
from mcp_stdio import (RPC, owned, support_candidates, save, artifact_root,
                       require_unoptimized, close_owned_client, cleanup_fixture)


def main():
    global ROOT
    require_unoptimized()
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, help='Fresh evidence directory; defaults to a new temporary directory')
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--sha', required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--include-mutations', action='store_true',
                        help='Also validate the update input contract; no mutation calls are sent')
    args = parser.parse_args()
    args.binary = args.binary.resolve(strict=True)
    ROOT = artifact_root(args.output)
    assert hashlib.sha256(args.binary.read_bytes()).hexdigest() == args.sha
    assert args.label.replace('-', '').isalnum()
    output = ROOT / (args.label + '.json')
    assert not output.exists()
    vault = owned(Path(tempfile.mkdtemp(prefix='schema-contract-', dir=ROOT)))
    identity = vault.lstat()
    (vault / 'notes').mkdir()
    support = support_candidates(vault)
    assert not any(p.exists() or p.is_symlink() for p in support)
    client = None
    report = {'binary': str(args.binary), 'sha256': args.sha, 'cases': [],
              'schema_validator': 'jsonschema' + importlib.metadata.version('jsonschema') + '/Draft202012'}
    try:
        client = RPC(args.binary, vault, not args.include_mutations)
        report['initialize'] = client.initialize()
        tools, report['discovery'] = discover(client)
        coverage = {'complete': False, 'failed_files': 1, 'failed_by_format': {'markdown': 1},
                    'complete_formats': ['json'],
                    'samples': [{'path': 'notes/broken.md', 'reason': 'invalid_document'}],
                    'samples_truncated': False}
        cases = [
            ('search_vault', 'complete success', {'results': [], 'coverage': {'complete': True}}, True),
            ('search_vault', 'incomplete success', {'results': [], 'coverage': coverage}, True),
            ('search_vault', 'missing format counts', {'results': [], 'coverage': {key: value for key, value in coverage.items() if key != 'failed_by_format'}}, False),
            ('search_vault', 'unknown coverage format', {'results': [], 'coverage': dict(coverage, failed_by_format={'unknown': 1})}, False),
            ('search_vault', 'zero failed format count', {'results': [], 'coverage': dict(coverage, failed_by_format={'markdown': 0})}, False),
            ('search_vault', 'missing complete formats', {'results': [], 'coverage': {key: value for key, value in coverage.items() if key != 'complete_formats'}}, False),
            ('search_vault', 'unknown complete format', {'results': [], 'coverage': dict(coverage, complete_formats=['unknown'])}, False),
            ('search_vault', 'duplicate complete format', {'results': [], 'coverage': dict(coverage, complete_formats=['json', 'json'])}, False),
            ('search_vault', 'no certified formats', {'results': [], 'coverage': dict(coverage, complete_formats=[])}, True),
            ('search_vault', 'missing incomplete facts', {'results': [], 'coverage': {'complete': False}}, False),
            ('search_vault', 'complete contradicts failures', {'results': [], 'coverage': dict(coverage, complete=True)}, False),
            ('search_vault', 'Canvas locator without field', {'results': [{'path': 'notes/a.canvas', 'format': 'canvas',
                  'canvas_node_id': 'node'}], 'coverage': {'complete': True}}, False),
            ('query_links', 'resolved path without format', {'direction': 'resolve', 'results': [
                {'target': 'A', 'kind': 'link', 'resolved_path': 'notes/A.md', 'ambiguous': False}],
                'coverage': {'complete': True}}, False),
            ('query_links', 'resolved format without path', {'direction': 'resolve', 'results': [
                {'target': 'A', 'kind': 'link', 'resolved_format': 'markdown', 'ambiguous': False}],
                'coverage': {'complete': True}}, False),
        ]
        for name, label, instance, expected in cases:
            errors = list(Draft202012Validator(tools[name]['outputSchema']).iter_errors(instance))
            valid = not errors
            report['cases'].append({'tool': name, 'label': label, 'instance': instance,
                                    'expected_valid': expected, 'actual_valid': valid,
                                    'passed': valid == expected,
                                    'errors': [error.message for error in errors]})
        if args.include_mutations:
            update = tools['update_file']['inputSchema']
            validator = Draft202012Validator(update)
            supported = {
                'markdown': {'replace', 'append', 'patch'}, 'canvas': {'replace'},
                'csv': {'replace', 'append', 'patch'}, 'json': {'replace', 'patch'},
                'log': {'append'}, 'har': set(), 'patch': set(), 'png': set(), 'gif': set(),
            }
            for format_name, modes in supported.items():
                for mode in ['replace', 'append', 'patch']:
                    instance = {'format': format_name, 'path': 'notes/example.' + format_name,
                                'expected_revision': 'sha256:' + 'a' * 64, 'mode': mode}
                    if mode == 'patch':
                        instance['replacements'] = [{'old_text': 'before', 'new_text': 'after'}]
                    else:
                        instance['content'] = 'replacement'
                    expected = mode in modes
                    valid = validator.is_valid(instance)
                    report['cases'].append({'tool': 'update_file', 'schema': 'input',
                        'label': format_name + '/' + mode, 'instance': instance,
                        'expected_valid': expected, 'actual_valid': valid, 'passed': valid == expected})
            base = {'format': 'markdown', 'path': 'notes/example.md',
                    'expected_revision': 'sha256:' + 'a' * 64}
            invalid_payloads = [
                {'mode': 'replace'}, {'mode': 'append'},
                {'mode': 'patch'}, {'mode': 'patch', 'replacements': []},
                {'mode': 'patch', 'replacements': [{'old_text': '', 'new_text': 'after'}]},
                {'mode': 'patch', 'replacements': [{'old_text': 'before'}]},
                {'mode': 'patch', 'content': 'wrong', 'replacements': [{'old_text': 'a', 'new_text': 'b'}]},
                {'mode': 'replace', 'content': 'x', 'replacements': []},
                {'mode': 'append', 'content': 'x', 'unexpected': True},
            ]
            for index, payload in enumerate(invalid_payloads):
                instance = dict(base, **payload)
                valid = validator.is_valid(instance)
                report['cases'].append({'tool': 'update_file', 'schema': 'input',
                    'label': 'invalid payload ' + str(index), 'instance': instance,
                    'expected_valid': False, 'actual_valid': valid, 'passed': not valid})
            properties = update.get('properties', {})
            visible = {'format', 'path', 'expected_revision', 'mode', 'content', 'replacements'} <= properties.keys()
            report['cases'].append({'tool': 'update_file', 'label': 'flat discoverable fields without root union',
                                    'passed': visible and 'oneOf' not in update and 'anyOf' not in update})
        report['all_passed'] = all(case['passed'] for case in report['cases'])
    except BaseException as error:
        report['error'] = repr(error)
        report['all_passed'] = False
    finally:
        reaped = client is None or close_owned_client(client, report, 'exit')
        if reaped:
            cleanup_fixture(vault, identity, support, report)
        else:
            report['cleanup_skipped'] = 'Child exit not confirmed; owned fixture retained'
        report['all_passed'] = (report.get('all_passed', False)
                                and not report.get('error')
                                and not report.get('shutdown_error')
                                and not report.get('cleanup_errors'))
        save(output, report)
    print(json.dumps({'all_passed': report['all_passed'], 'cases': report['cases']}, indent=2))
    raise SystemExit(0 if report['all_passed'] else 1)


if __name__ == '__main__':
    main()
