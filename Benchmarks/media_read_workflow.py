#!/usr/bin/env python3
"""Paired image-read latency/payload checks using only disposable vaults.

Requires Pillow for generated GIF fixtures. Existing mcp_stdio transport measures
request write-start through complete-frame arrival; image checks run afterward.
Default inspection and explicit rendering are reported separately, never conflated.
"""
import argparse
import base64
import hashlib
import io
import json
import math
import statistics
import tempfile
from pathlib import Path

from PIL import Image, __version__ as pillow_version
from native_fixtures import png_bytes
from mcp_stdio import (RPC, artifact_root, owned, support_candidates, save,
                       require_unoptimized, close_owned_client, cleanup_fixture)


def summarize(rows):
    groups = {}
    for row in rows:
        if row['kind'] == 'media' and 'image_blocks' in row:
            key = row['variant'] + '/' + row['format'] + '/' + row['mode']
            groups.setdefault(key, []).append(row)
    result = {}
    for key, values in groups.items():
        elapsed = sorted(row['elapsed_ms'] for row in values)
        result[key] = {
            'samples': len(values), 'p50_ms': statistics.median(elapsed),
            'p95_ms': elapsed[math.ceil(len(elapsed) * .95) - 1],
            'response_bytes_min': min(row['response_bytes'] for row in values),
            'response_bytes_max': max(row['response_bytes'] for row in values),
            'image_blocks': sorted({row['image_blocks'] for row in values}),
        }
    return result


# Frozen before candidate measurements. Inspection timings are informational;
# equivalent explicit rendering must satisfy both comparative and engineering caps.
GATES = {'render_p95_ratio': 1.2, 'render_p95_slack_ms': 5.0,
         'candidate_p95_ms': 500.0, 'candidate_single_ms': 1000.0}
GIF_SAMPLE_INDICES = [0, 3, 5, 8, 11, 14, 16, 19]


def validate_media(row, format_name, expected, source):
    assert row['success'], row
    body = row['response']['result']
    assert all(block['type'] in ('text', 'image') for block in body['content'])
    images = [block for block in body['content'] if block['type'] == 'image']
    row['image_blocks'] = len(images)
    assert len(images) == expected
    for offset, image in enumerate(images):
        assert image['mimeType'] == 'image/png'
        raw = base64.b64decode(image['data'], validate=True)
        with Image.open(io.BytesIO(raw)) as decoded:
            assert decoded.format == 'PNG' and decoded.size == (512, 384)
            decoded.load()  # Header dimensions alone do not validate compressed pixels.
            rgb = decoded.convert('RGB')
            if format_name == 'png':
                with Image.open(io.BytesIO(source)) as original:
                    original.load()
                    assert rgb.tobytes() == original.convert('RGB').tobytes()
            else:
                index = GIF_SAMPLE_INDICES[offset]
                expected_color = (index * 11, 120, 255 - index * 11)
                # Allow at most one integer rounding step from native color conversion.
                for (low, high), channel in zip(rgb.getextrema(), expected_color):
                    assert abs(low - channel) <= 1 and abs(high - channel) <= 1
        image.pop('data')
        image.update(verified_bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())
    assert body['structuredContent']['revision'] == 'sha256:' + hashlib.sha256(source).hexdigest()
    row['media_verified'] = True


def evaluate(report):
    correctness, performance = [], []
    count = report.get('samples_per_variant')
    rows = report.get('calls', [])
    if type(count) is not int or not 1 <= count <= 100:
        correctness.append('Invalid sample count')
        count = 0
    expected = {(kind, variant, format_name, mode, sample)
                for kind in ['media', 'following_text']
                for variant in ['baseline', 'candidate']
                for format_name in ['png', 'gif']
                for mode in ['inspection', 'rendering']
                for sample in range(count)}
    keyed = {}
    for row in rows:
        key = tuple(row.get(field) for field in ['kind', 'variant', 'format', 'mode', 'sample'])
        if key not in expected or key in keyed:
            correctness.append('Unexpected or duplicate row key')
            continue
        keyed[key] = row
        latency = row.get('elapsed_ms')
        if type(latency) not in (int, float) or not math.isfinite(latency) or latency < 0:
            correctness.append('Invalid latency')
        if row.get('success') is not True:
            correctness.append('Failed raw call')
        flag = 'media_verified' if key[0] == 'media' else 'following_verified'
        if row.get(flag) is not True:
            correctness.append('Unverified response')
        if key[0] == 'media':
            visible = key[1] == 'baseline' or key[3] == 'rendering'
            image_count = (1 if key[2] == 'png' else 8) if visible else 0
            if row.get('image_blocks') != image_count:
                correctness.append('Unexpected image count')
            if type(row.get('response_bytes')) is not int or row['response_bytes'] <= 0:
                correctness.append('Invalid response size')
    if set(keyed) != expected:
        correctness.append('Incomplete raw call grid')
    for variant in ['baseline', 'candidate']:
        exit_result = report.get(variant + '_exit', {})
        if exit_result.get('exit_code') != 0 or exit_result.get('forced_signals') != 0:
            correctness.append('Missing or unclean process exit')
    if not report.get('all_passed') or any(report.get(key) for key in [
        'error', 'shutdown_error', 'cleanup_errors', 'cleanup_skipped'
    ]) or not report.get('cleanup'):
        correctness.append('Incomplete execution or failed cleanup')
    report['summary'] = summarize([row for row in rows
        if row.get('success') is True and row.get('media_verified') is True
        and type(row.get('elapsed_ms')) in (int, float) and math.isfinite(row['elapsed_ms'])
        and row['elapsed_ms'] >= 0
        and type(row.get('response_bytes')) is int and row['response_bytes'] > 0])
    if not correctness:
        for format_name in ['png', 'gif']:
            baseline = report['summary']['baseline/' + format_name + '/rendering']['p95_ms']
            candidate = report['summary']['candidate/' + format_name + '/rendering']['p95_ms']
            if candidate > max(GATES['render_p95_ratio'] * baseline, baseline + GATES['render_p95_slack_ms']):
                performance.append(format_name + ': equivalent-render p95 regression')
            for mode in ['inspection', 'rendering']:
                group = [keyed[('media', 'candidate', format_name, mode, sample)]
                         for sample in range(count)]
                if report['summary']['candidate/' + format_name + '/' + mode]['p95_ms'] > GATES['candidate_p95_ms']:
                    performance.append(format_name + '/' + mode + ': p95 exceeds engineering cap')
                if max(row['elapsed_ms'] for row in group) > GATES['candidate_single_ms']:
                    performance.append(format_name + '/' + mode + ': single-call engineering cap')
            for sample in range(count):
                before = keyed[('media', 'baseline', format_name, 'inspection', sample)]
                after = keyed[('media', 'candidate', format_name, 'inspection', sample)]
                if after['response_bytes'] >= before['response_bytes']:
                    performance.append(format_name + ': inspection payload did not decrease')
    report.update(gates=dict(GATES), correctness_errors=correctness, performance_errors=performance,
                  correctness_passed=not correctness, performance_evaluated=not correctness,
                  performance_passed=not correctness and not performance,
                  all_passed=not correctness and not performance)
    return report


def main():
    require_unoptimized()
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--baseline-sha', required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--candidate-sha', required=True)
    parser.add_argument('--samples', type=int, default=30)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.samples <= 100:
        parser.error('--samples must be 1..100')
    binaries = {'baseline': args.baseline.resolve(strict=True),
                'candidate': args.candidate.resolve(strict=True)}
    for name, expected in [('baseline', args.baseline_sha), ('candidate', args.candidate_sha)]:
        assert hashlib.sha256(binaries[name].read_bytes()).hexdigest() == expected
    root = artifact_root(args.output)
    vault = owned(Path(tempfile.mkdtemp(prefix='media-read-', dir=root)))
    identity = vault.lstat()
    support = support_candidates(vault)
    assert not any(path.exists() or path.is_symlink() for path in support)
    (vault / 'notes').mkdir()
    raw_png = png_bytes(512, 384)
    (vault / 'notes/image.png').write_bytes(raw_png)
    frames = [Image.new('RGB', (512, 384), (index * 11, 120, 255 - index * 11))
              for index in range(20)]
    gif = io.BytesIO()
    frames[0].save(gif, format='GIF', save_all=True, append_images=frames[1:],
                   duration=100, loop=0, optimize=False)
    raw_gif = gif.getvalue()
    (vault / 'notes/image.gif').write_bytes(raw_gif)
    (vault / 'notes/unrelated.md').write_text('unrelated result\n')
    report = {'baseline_sha256': args.baseline_sha, 'candidate_sha256': args.candidate_sha,
              'pillow_version': pillow_version, 'samples_per_variant': args.samples,
              'fixture': {'dimensions': [512, 384], 'gif_frames': 20, 'gif_duration_ms': 2000,
                          'png_bytes': len(raw_png), 'gif_bytes': len(raw_gif),
                          'png_sha256': hashlib.sha256(raw_png).hexdigest(),
                          'gif_sha256': hashlib.sha256(raw_gif).hexdigest()},
              'calls': [], 'all_passed': False}
    clients = {}
    reaped = True
    try:
        for variant, binary in binaries.items():
            client = RPC(binary, vault, True)
            clients[variant] = client
            report[variant + '_initialize'] = client.initialize()
        for sample in range(args.samples):
            variants = ['baseline', 'candidate']
            if sample % 2:
                variants.reverse()
            for variant in variants:
                client = clients[variant]
                for format_name in ['png', 'gif']:
                    for mode in ['inspection', 'rendering']:
                        arguments = {'format': format_name, 'path': 'notes/image.' + format_name}
                        if variant == 'candidate' and mode == 'rendering':
                            arguments['render'] = True
                        row = client.wait(client.call('read_file', arguments))
                        row.update(kind='media', variant=variant, sample=sample,
                                   format=format_name, mode=mode, arguments=arguments)
                        report['calls'].append(row)
                        expected = (1 if format_name == 'png' else 8) if (
                            variant == 'baseline' or mode == 'rendering') else 0
                        source = raw_png if format_name == 'png' else raw_gif
                        validate_media(row, format_name, expected, source)
                        following = client.wait(client.call('read_file', {
                            'format': 'markdown', 'path': 'notes/unrelated.md'}))
                        following.update(kind='following_text', variant=variant, sample=sample,
                                         format=format_name, mode=mode)
                        report['calls'].append(following)
                        assert following['success']
                        blocks = following['response']['result']['content']
                        assert blocks[0]['text'] == 'unrelated result\n'
                        assert all(block['type'] == 'text' for block in blocks)
                        following['following_verified'] = True
            save(root / 'media-read.json', report)
        report['all_passed'] = True
    except BaseException as error:
        report['error'] = repr(error)
    finally:
        for variant, client in clients.items():
            reaped = close_owned_client(client, report, variant + '_exit') and reaped
        if reaped:
            cleanup_fixture(vault, identity, support, report)
        else:
            report['cleanup_skipped'] = 'Child exit unconfirmed; fixture retained'
        evaluate(report)
        save(root / 'media-read.json', report)
    print(json.dumps({key: report[key] for key in [
        'all_passed', 'correctness_passed', 'performance_passed',
        'correctness_errors', 'performance_errors', 'summary'
    ]}, indent=2))
    raise SystemExit(0 if report['all_passed'] else 1)


if __name__ == '__main__':
    main()
