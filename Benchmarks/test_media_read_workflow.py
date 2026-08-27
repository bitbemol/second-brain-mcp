"""Isolated media-oracle controls: no server, subprocess, or filesystem mutation."""
import base64
import copy
import hashlib
import io
import unittest

from PIL import Image
from media_read_workflow import evaluate, validate_media
from native_fixtures import png_bytes


def encoded_png(color=(0, 120, 255)):
    output = io.BytesIO()
    Image.new('RGB', (512, 384), color).save(output, format='PNG')
    return output.getvalue()


def media_row(images, source):
    return {'success': True, 'response': {'result': {
        'content': [{'type': 'image', 'mimeType': mime, 'data': base64.b64encode(raw).decode()}
                    for mime, raw in images],
        'structuredContent': {'revision': 'sha256:' + hashlib.sha256(source).hexdigest()},
    }}}


def complete_report():
    report = {'samples_per_variant': 1, 'all_passed': True, 'calls': [],
              'baseline_exit': {'exit_code': 0, 'forced_signals': 0},
              'candidate_exit': {'exit_code': 0, 'forced_signals': 0},
              'cleanup': [{'removed_owned_directory': 'owned-fixture'}], 'cleanup_errors': []}
    for variant in ['baseline', 'candidate']:
        for format_name in ['png', 'gif']:
            for mode in ['inspection', 'rendering']:
                visible = variant == 'baseline' or mode == 'rendering'
                common = {'variant': variant, 'format': format_name, 'mode': mode,
                          'sample': 0, 'elapsed_ms': 10.0, 'success': True}
                report['calls'].append(dict(common, kind='media', media_verified=True,
                    image_blocks=(1 if format_name == 'png' else 8) if visible else 0,
                    response_bytes=10000 if visible else 500))
                report['calls'].append(dict(common, kind='following_text', following_verified=True,
                                            response_bytes=100))
    return report


class MediaOracleTests(unittest.TestCase):
    def test_valid_images_and_report(self):
        source = png_bytes(512, 384)
        validate_media(media_row([('image/png', source)], source), 'png', 1, source)
        frames = [('image/png', encoded_png((index * 11, 120, 255 - index * 11)))
                  for index in [0, 3, 5, 8, 11, 14, 16, 19]]
        validate_media(media_row(frames, b'gif-fixture'), 'gif', 8, b'gif-fixture')
        report = evaluate(complete_report())
        self.assertTrue(report['all_passed'])

    def test_rejects_mime_mismatch(self):
        source = png_bytes(512, 384)
        with self.assertRaises((AssertionError, ValueError)):
            validate_media(media_row([('image/jpeg', source)], source), 'png', 1, source)

    def test_rejects_truncated_pixels_despite_valid_header(self):
        source = png_bytes(512, 384)
        truncated = source[:len(source) // 2]
        with Image.open(io.BytesIO(truncated)) as decoded:
            self.assertEqual(decoded.size, (512, 384))
        with self.assertRaises((AssertionError, OSError, ValueError)):
            validate_media(media_row([('image/png', truncated)], source), 'png', 1, source)

    def test_rejects_wrong_png_pixels(self):
        source = png_bytes(512, 384)
        with self.assertRaises((AssertionError, ValueError)):
            validate_media(media_row([('image/png', encoded_png())], source), 'png', 1, source)

    def test_rejects_repeated_or_wrong_sampled_gif_frames(self):
        with self.assertRaises((AssertionError, ValueError)):
            validate_media(media_row([('image/png', encoded_png())] * 8, b'gif-fixture'),
                           'gif', 8, b'gif-fixture')

    def test_rejects_incomplete_duplicate_or_failed_grid(self):
        for mutation in [
            lambda r: r['calls'].pop(),
            lambda r: r['calls'].append(copy.deepcopy(r['calls'][0])),
            lambda r: r['calls'][0].update(success=False),
            lambda r: r['calls'][0].update(media_verified=False),
            lambda r: r['calls'][0].pop('response_bytes'),
            lambda r: r['calls'][1].update(following_verified=False),
            lambda r: r.pop('candidate_exit'),
            lambda r: r['candidate_exit'].update(forced_signals=1),
        ]:
            report = complete_report()
            mutation(report)
            self.assertFalse(evaluate(report)['all_passed'])

    def test_rejects_relative_and_absolute_latency_failures(self):
        for latency in [16.0, 501.0, 1001.0, float('nan'), float('inf')]:
            with self.subTest(latency=latency):
                report = complete_report()
                for row in report['calls']:
                    if row['kind'] == 'media' and row['variant'] == 'candidate' and row['mode'] == 'rendering':
                        row['elapsed_ms'] = latency
                self.assertFalse(evaluate(report)['all_passed'])

    def test_absolute_gate_applies_without_relative_failure(self):
        report = complete_report()
        for row in report['calls']:
            if row['kind'] == 'media':
                row['elapsed_ms'] = 501.0
        self.assertFalse(evaluate(report)['all_passed'])

    def test_inspection_requires_no_images_and_smaller_payload(self):
        for field, value in [('image_blocks', 1), ('response_bytes', 10000)]:
            report = complete_report()
            for row in report['calls']:
                if row['kind'] == 'media' and row['variant'] == 'candidate' and row['mode'] == 'inspection':
                    row[field] = value
            self.assertFalse(evaluate(report)['all_passed'])

    def test_primary_and_cleanup_failures_are_retained(self):
        for failure in [{'error': 'primary'}, {'shutdown_error': 'exit'},
                        {'cleanup_errors': ['cleanup']}, {'cleanup_skipped': 'unreaped'}]:
            report = complete_report()
            report.update(failure)
            self.assertFalse(evaluate(report)['all_passed'])
            for key, value in failure.items():
                self.assertEqual(report[key], value)


if __name__ == '__main__':
    unittest.main()
