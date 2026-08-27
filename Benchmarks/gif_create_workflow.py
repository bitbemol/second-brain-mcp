#!/usr/bin/env python3
"""Real stdio GIF-create pairs. No token, large-video, or pure-encoder speed claim."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import tempfile

from mcp_stdio import (RPC, artifact_root, owned, support_candidates, save,
                       require_unoptimized, close_owned_client, cleanup_fixture)
from native_fixtures import png_bytes

GATES = {'p95_ratio': 1.2, 'p95_slack_ms': 5.0}
FIXTURE = {'width': 64, 'height': 48, 'frames': 259, 'fps': 10, 'duration_ms': 25900}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def valid_hash(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def check_call(call):
    assert call['success'] is True
    raw = call['response']
    assert 'error' not in raw and raw['result'].get('isError') is not True
    duration = call['elapsed_ms']
    assert type(duration) in (int, float) and math.isfinite(duration) and 0 <= duration <= 45000
    for field in ('request_bytes', 'response_bytes'):
        assert type(call[field]) is int and call[field] > 0
    return raw['result']


def check_row(row):
    assert type(row['sample']) is int and row['sample'] >= 0
    assert row['variant'] in ('baseline', 'candidate')
    assert row['source_unchanged'] is True
    facts = row['facts']
    for key, expected in [('width', 64), ('height', 48), ('frames', 120), ('duration_ms', 26400)]:
        assert type(facts[key]) is int and facts[key] == expected, (key, facts)
    assert type(facts['bytes']) is int and 0 < facts['bytes'] <= 50 * 1024 * 1024
    assert valid_hash(facts['sha256'])
    check_call(row['initialize'])
    for operation in ('create', 'read'):
        result = check_call(row[operation])
        blocks = result['content']
        assert blocks and all(block['type'] == 'text' and isinstance(block['text'], str) for block in blocks)
        text = '\n'.join(block['text'] for block in blocks)
        assert result['structuredContent']['revision'] == 'sha256:' + facts['sha256']
        # Old creation metadata is the diagnosed defect, never a failed workload.
        if operation == 'read' or row['variant'] == 'candidate':
            for value in ('64×48', '120 frames', '26.4s'):
                assert re.search(r'(?<![0-9])' + re.escape(value) + r'(?![0-9])', text), text
    assert row['exit']['exit_code'] == 0 and row['exit']['forced_signals'] == 0
    assert not any(row.get(key) for key in ('error', 'shutdown_error', 'cleanup_errors', 'cleanup_skipped'))
    assert row['cleanup_verified_absent'] is True
    assert {'removed_owned_directory': row['vault']} in row['cleanup']


def evaluate(report):
    """Recompute from the full grid and raw calls, never a filtered timing summary."""
    errors = []
    rows = report.get('rows', [])
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        errors.append('Malformed raw row collection')
        rows = []
    count = report.get('samples_per_variant')
    try:
        assert type(count) is int and 1 <= count <= 100
        assert report['execution_complete'] is True
        assert not report.get('error')
        assert valid_hash(report['baseline_sha256']) and valid_hash(report['candidate_sha256'])
        for key, value in FIXTURE.items():
            assert report['fixture'][key] == value
        assert valid_hash(report['fixture']['source_sha256'])
        expected = [(sample, variant) for sample in range(count)
                    for variant in (['baseline', 'candidate'] if sample % 2 == 0
                                    else ['candidate', 'baseline'])]
        assert [(row.get('sample'), row.get('variant')) for row in rows] == expected
    except (AssertionError, KeyError, TypeError, AttributeError):
        errors.append('Invalid identity, fixture, completion, or exact alternating grid')
    for index, row in enumerate(rows):
        try:
            check_row(row)
        except (AssertionError, KeyError, TypeError, ValueError, AttributeError):
            errors.append('Invalid raw row ' + str(index))
    summary = {}
    performance_errors = []
    if not errors:
        for variant in ('baseline', 'candidate'):
            values = sorted(row['create']['elapsed_ms'] for row in rows if row['variant'] == variant)
            summary[variant] = {
                'samples': len(values), 'p50_ms': statistics.median(values),
                'p95_ms': values[math.ceil(.95 * len(values)) - 1], 'maximum_ms': max(values),
                'response_bytes': sorted({row['create']['response_bytes'] for row in rows
                                          if row['variant'] == variant})}
        before, after = summary['baseline'], summary['candidate']
        ceiling = max(before['p95_ms'] * GATES['p95_ratio'],
                      before['p95_ms'] + GATES['p95_slack_ms'])
        summary.update(p95_ceiling_ms=ceiling,
                       p50_delta_percent=(after['p50_ms'] / before['p50_ms'] - 1) * 100
                       if before['p50_ms'] else None,
                       p95_delta_percent=(after['p95_ms'] / before['p95_ms'] - 1) * 100
                       if before['p95_ms'] else None)
        if count >= 30 and after['p95_ms'] > ceiling:
            performance_errors.append('GIF create p95 exceeded frozen no-regression gate')
    return {'passed': not errors and not performance_errors,
            'performance_evaluated': not errors and count is not None and count >= 30,
            'correctness_errors': errors, 'performance_errors': performance_errors,
            'gates': dict(GATES), 'summary': summary}


def gif_facts(path):
    from PIL import Image
    data = path.read_bytes()
    assert 0 < len(data) <= 50 * 1024 * 1024
    with Image.open(path) as image:
        assert image.format == 'GIF' and image.size == (64, 48)
        count = image.n_frames
        assert count == 120
        duration = 0
        for index in range(count):
            image.seek(index)
            image.load()  # Validate encoded frames after the timed create call.
            delay = image.info.get('duration')
            assert type(delay) is int and delay > 0
            duration += delay
        return {'width': image.width, 'height': image.height, 'frames': count,
                'duration_ms': duration, 'bytes': len(data),
                'sha256': hashlib.sha256(data).hexdigest()}


def run_one(binary, variant, sample, root, source, source_hash):
    vault = owned(Path(tempfile.mkdtemp(prefix='gif-' + variant + '-', dir=root)))
    identity = vault.lstat()
    support = support_candidates(vault)
    row = {'sample': sample, 'variant': variant, 'vault': str(vault)}
    client = None
    reaped = True
    owned_support = []
    try:
        assert not any(path.exists() or path.is_symlink() for path in support)
        owned_support = support
        (vault / 'notes').mkdir()
        (vault / 'references').mkdir()
        client = RPC(binary, vault, False)
        row['initialize'] = client.initialize()
        row['create'] = client.wait(client.call('create_file', {
            'format': 'gif', 'path': 'notes/import.gif', 'source': str(source),
            'transform': 'video_to_gif'}))
        check_call(row['create'])
        stored = vault / 'notes/import.gif'
        row['facts'] = gif_facts(stored)
        artifact = root / ('encoded-' + row['facts']['sha256'] + '.gif')
        if artifact.exists():
            assert sha256(artifact) == row['facts']['sha256']
        else:
            with artifact.open('xb') as output:
                output.write(stored.read_bytes())
        row['artifact'] = artifact.name
        row['read'] = client.wait(client.call('read_file', {
            'format': 'gif', 'path': 'notes/import.gif'}))
        row['source_unchanged'] = sha256(source) == source_hash
    except BaseException as error:
        row['error'] = repr(error)
    finally:
        if client is not None:
            reaped = close_owned_client(client, row, 'exit')
        if reaped:
            cleanup_fixture(vault, identity, owned_support, row)
            row['cleanup_verified_absent'] = not any(
                path.exists() or path.is_symlink() for path in [vault] + support)
        else:
            row['cleanup_skipped'] = 'Child exit unconfirmed; fixture retained'
    return row


def make_fixture(root, report):
    png = root / 'fixture.png'
    png.write_bytes(png_bytes(64, 48))
    generator = root / 'gif-fixture-generator'
    command = ['/usr/bin/xcrun', 'swiftc', '-O', '-parse-as-library',
               str(Path(__file__).with_name('gif_create_fixture.swift')),
               '-module-cache-path', str(root / 'module-cache'), '-o', str(generator)]
    compile_result = subprocess.run(command, capture_output=True, timeout=60)
    report['fixture_compile'] = {'exit_code': compile_result.returncode,
                                 'stderr': compile_result.stderr.decode(errors='replace')[:32768]}
    assert compile_result.returncode == 0, report['fixture_compile']
    source = root / 'source.mov'
    generated = subprocess.run([str(generator), str(png), str(source)],
                               capture_output=True, timeout=45)
    report['fixture_generation'] = {'exit_code': generated.returncode,
                                    'stdout': generated.stdout.decode(errors='replace')[:32768],
                                    'stderr': generated.stderr.decode(errors='replace')[:32768]}
    assert generated.returncode == 0, report['fixture_generation']
    source_hash = sha256(source)
    report['fixture'].update(source_sha256=source_hash, source_bytes=source.stat().st_size,
                             png_sha256=sha256(png))
    return source, source_hash


def main():
    require_unoptimized()
    parser = argparse.ArgumentParser(description=__doc__)
    for variant in ('baseline', 'candidate'):
        parser.add_argument('--' + variant, type=Path, required=True)
        parser.add_argument('--' + variant + '-sha', required=True)
    parser.add_argument('--samples', type=int, default=30)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.samples <= 100:
        parser.error('--samples must be 1..100')
    binaries = {variant: getattr(args, variant).resolve(strict=True)
                for variant in ('baseline', 'candidate')}
    for variant in binaries:
        assert sha256(binaries[variant]) == getattr(args, variant + '_sha')
    root = artifact_root(args.output)
    report = {'samples_per_variant': args.samples, 'baseline_sha256': args.baseline_sha,
              'candidate_sha256': args.candidate_sha, 'fixture': dict(FIXTURE),
              'rows': [], 'execution_complete': False,
              'scope': 'Fresh-process full create including vault snapshot, tiny 120-frame GIF; not resize/large-media or isolated encoder performance'}
    report['provenance'] = {
        'binary_paths': {name: str(path) for name, path in binaries.items()},
        'python_version': __import__('sys').version,
        'pillow_version': __import__('PIL').__version__,
        'harness_sha256': sha256(Path(__file__)),
        'fixture_generator_sha256': sha256(Path(__file__).with_name('gif_create_fixture.swift')),
        'stdio_helper_sha256': sha256(Path(__file__).with_name('mcp_stdio.py')),
        'native_fixture_helper_sha256': sha256(Path(__file__).with_name('native_fixtures.py')),
    }
    try:
        source, source_hash = make_fixture(root, report)
        for sample in range(args.samples):
            for variant in (['baseline', 'candidate'] if sample % 2 == 0
                            else ['candidate', 'baseline']):
                row = run_one(binaries[variant], variant, sample, root, source, source_hash)
                report['rows'].append(row)
                save(root / 'gif-create.json', report)
                check_row(row)
            print(json.dumps({'completed_pairs': sample + 1, 'planned_pairs': args.samples}), flush=True)
        report['execution_complete'] = True
    except BaseException as error:
        report['error'] = repr(error)
    finally:
        report['analysis'] = evaluate(report)
        save(root / 'gif-create.json', report)
    print(json.dumps(report['analysis'], indent=2), flush=True)
    raise SystemExit(0 if report['analysis']['passed'] else 1)


if __name__ == '__main__':
    main()
