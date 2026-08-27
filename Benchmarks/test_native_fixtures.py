import hashlib
from pathlib import Path
import re
import struct
import tempfile
import unittest
import zlib

from native_fixtures import (MIB, expansion_commands, ocr_image, png_bytes,
                             png_dimensions, write_pdf)


class NativeFixtureTests(unittest.TestCase):
    def test_png_has_valid_chunks_and_exact_pixels(self):
        raw = png_bytes()
        self.assertEqual(png_dimensions(raw), (32, 24))
        cursor = 8
        decoded = b''
        while cursor < len(raw):
            length = struct.unpack('>I', raw[cursor:cursor + 4])[0]
            kind = raw[cursor + 4:cursor + 8]
            value = raw[cursor + 8:cursor + 8 + length]
            crc = struct.unpack('>I', raw[cursor + 8 + length:cursor + 12 + length])[0]
            self.assertEqual(crc, zlib.crc32(kind + value) & 0xffffffff)
            if kind == b'IDAT':
                decoded += zlib.decompress(value)
            cursor += length + 12
        self.assertEqual(cursor, len(raw))
        self.assertEqual(len(decoded), 24 * (1 + 32 * 3))
        self.assertEqual(decoded[0], 0)

    def assert_pdf_xref(self, path, manifest):
        raw = path.read_bytes()
        self.assertEqual(len(raw), manifest['bytes'])
        self.assertEqual(hashlib.sha256(raw).hexdigest(), manifest['sha256'])
        xref = int(raw.rsplit(b'startxref\n', 1)[1].splitlines()[0])
        self.assertEqual(raw[xref:xref + 5], b'xref\n')
        lines = raw[xref:].splitlines()
        count = int(lines[1].split()[1])
        self.assertEqual(lines[2], b'0000000000 65535 f ')
        for identifier, entry in enumerate(lines[3:count + 2], 1):
            offset = int(entry[:10])
            self.assertTrue(raw[offset:].startswith(f'{identifier} 0 obj\n'.encode()))
        self.assertIn(f'/Count {manifest["pages"]}'.encode(), raw)
        return raw

    def test_exact_padding_and_xref(self):
        with tempfile.TemporaryDirectory() as temporary:
            for size in (4096, 65536):
                path = Path(temporary) / f'{size}.pdf'
                manifest = write_pdf(path, target_bytes=size)
                raw = self.assert_pdf_xref(path, manifest)
                self.assertEqual(len(raw), size)
                self.assertGreater(manifest['padding_stream_bytes'], 0)
                self.assertIn(b'nativegamma', raw)

    def test_compressed_stream_has_frozen_decoded_work(self):
        commands = expansion_commands()
        self.assertEqual(commands.count(b'expansionneedle'), 1024)
        self.assertEqual(sum(len(value) for value in re.findall(rb'\(([^()]*)\) Tj', commands)), 256 * 1024)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'expansion.pdf'
            manifest = write_pdf(path, pages=('expansion',), expansion=True)
            raw = self.assert_pdf_xref(path, manifest)
            compressed = raw.split(b'/Filter /FlateDecode >>\nstream\n', 1)[1].split(b'\nendstream', 1)[0]
            self.assertEqual(zlib.decompress(compressed), commands)
            self.assertEqual(manifest['decoded_content_command_bytes'], len(commands))

    def test_ocr_fixture_is_image_only_and_bounded(self):
        pixels, width, height = ocr_image()
        self.assertEqual(len(pixels), width * height)
        self.assertLessEqual(len(pixels), 100000)
        self.assertEqual(set(pixels), {0, 255})
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'ocr.pdf'
            manifest = write_pdf(path, ocr_pages=64)
            raw = self.assert_pdf_xref(path, manifest)
            self.assertEqual(manifest['declared_literal_text_bytes'], 0)
            self.assertNotIn(b' Tj', raw)
            self.assertEqual(raw.count(b'/Subtype /Image'), 1)

    def test_fixture_rejects_unbounded_or_overwriting_requests(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'fixture.pdf'
            with self.assertRaises(AssertionError):
                write_pdf(path, target_bytes=512 * MIB + 1)
            with self.assertRaises(AssertionError):
                write_pdf(path, ocr_pages=65)
            write_pdf(path)
            with self.assertRaises(AssertionError):
                write_pdf(path)


if __name__ == '__main__':
    unittest.main()
