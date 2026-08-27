"""Deterministic bounded PDF/PNG fixtures; Python standard library only."""
import hashlib
from pathlib import Path
import struct
import zlib

MIB = 1024 * 1024


def chunk(kind, value):
    return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value) & 0xffffffff)


def png_bytes(width=32, height=24):
    assert 1 <= width <= 2000 and 1 <= height <= 2000
    rows = b''
    for y in range(height):
        rows += b'\x00' + b''.join(bytes((x * 7 % 256, y * 9 % 256, (x + y) * 5 % 256))
                                    for x in range(width))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def png_dimensions(value):
    assert value[:8] == b'\x89PNG\r\n\x1a\n' and value[12:16] == b'IHDR'
    return struct.unpack('>II', value[16:24])


def pdf_literal(text):
    return text.encode('ascii').replace(b'\\', b'\\\\').replace(b'(', b'\\(').replace(b')', b'\\)')


def stream(value, compressed=False, properties=b''):
    encoded = zlib.compress(value) if compressed else value
    filters = b' /Filter /FlateDecode' if compressed else b''
    return b'<< /Length ' + str(len(encoded)).encode() + filters + properties + b' >>\nstream\n' + encoded + b'\nendstream'


def text_commands(text):
    return b'BT /F1 12 Tf 36 720 Td (' + pdf_literal(text) + b') Tj ET\n'


def expansion_commands():
    # Exactly 256 KiB literal text, in 1,024 independent positioned strings.
    row = 'expansionneedle ' + 'A' * (256 - len('expansionneedle '))
    command = b'BT /F1 8 Tf 36 720 Td (' + pdf_literal(row) + b') Tj ET\n'
    return command * 1024


def ocr_image():
    font = {
        'H': ['10001','10001','10001','11111','10001','10001','10001'],
        'E': ['11111','10000','10000','11110','10000','10000','11111'],
        'L': ['10000','10000','10000','10000','10000','10000','11111'],
        'O': ['01110','10001','10001','10001','10001','10001','01110'],
        'W': ['10001','10001','10001','10101','10101','10101','01010'],
        'R': ['11110','10001','10001','11110','10100','10010','10001'],
        'D': ['11110','10001','10001','10001','10001','10001','11110'],
        ' ': ['00000'] * 7,
    }
    scale, margin = 10, 20
    text = 'HELLO WORLD'
    width, height = (len(text) * 6 - 1) * scale + margin * 2, 7 * scale + margin * 2
    pixels = bytearray([255]) * (width * height)
    for letter, glyph in enumerate(text):
        for row, bits in enumerate(font[glyph]):
            for column, bit in enumerate(bits):
                if bit == '1':
                    for dy in range(scale):
                        start = (margin + row * scale + dy) * width + margin + (letter * 6 + column) * scale
                        pixels[start:start + scale] = b'\x00' * scale
    return bytes(pixels), width, height


def write_pdf(path, pages=('nativealpha', 'nativebeta', 'nativegamma'), target_bytes=None,
              expansion=False, ocr_pages=0):
    """Write a valid xref PDF, optionally padded by one unreferenced bounded stream."""
    path = Path(path)
    assert not path.exists()
    assert target_bytes is None or 4096 <= target_bytes <= 512 * MIB
    assert not (expansion and ocr_pages)
    assert 0 <= ocr_pages <= 64
    count = ocr_pages or len(pages)
    assert 1 <= count <= 64
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'', b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
               b'<< /Title (Native fixture title) /Author (Synthetic fixture) >>']
    image_number = None
    if ocr_pages:
        pixels, width, height = ocr_image()
        image_number = len(objects) + 1
        properties = f' /Type /XObject /Subtype /Image /Width {width} /Height {height} /ColorSpace /DeviceGray /BitsPerComponent 8'.encode()
        objects.append(stream(pixels, compressed=True, properties=properties))
    page_ids, decoded_bytes = [], 0
    for index in range(count):
        page_id, content_id = len(objects) + 1, len(objects) + 2
        page_ids.append(page_id)
        resources = b'/Font << /F1 3 0 R >>'
        if ocr_pages:
            resources += f' /XObject << /Im1 {image_number} 0 R >>'.encode()
            commands = b'q 572 0 0 96 20 350 cm /Im1 Do Q\n'
        else:
            commands = expansion_commands() if expansion else text_commands(pages[index])
        decoded_bytes += len(commands)
        objects.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << '.encode()
                       + resources + f' >> /Contents {content_id} 0 R >>'.encode())
        objects.append(stream(commands, compressed=expansion))
    objects[1] = f'<< /Type /Pages /Count {count} /Kids ['.encode() + b' '.join(f'{n} 0 R'.encode() for n in page_ids) + b'] >>'
    prefix = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
    offsets = [0]
    for index, value in enumerate(objects, 1):
        offsets.append(len(prefix))
        prefix += f'{index} 0 obj\n'.encode() + value + b'\nendobj\n'

    def trailer(current_offsets, xref):
        body = f'xref\n0 {len(current_offsets)}\n0000000000 65535 f \n'.encode()
        body += b''.join(f'{offset:010d} 00000 n \n'.encode() for offset in current_offsets[1:])
        return body + f'trailer\n<< /Size {len(current_offsets)} /Root 1 0 R /Info 4 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()

    padding = 0
    pad_header, pad_footer = b'', b''
    if target_bytes is not None:
        offsets.append(len(prefix))
        padding = target_bytes - len(prefix) - 1024
        assert padding >= 0
        for _ in range(8):
            pad_header = f'{len(objects) + 1} 0 obj\n<< /Length {padding} >>\nstream\n'.encode()
            pad_footer = b'\nendstream\nendobj\n'
            total = len(prefix) + len(pad_header) + padding + len(pad_footer)
            difference = target_bytes - total - len(trailer(offsets, total))
            if not difference:
                break
            padding += difference
        else:
            raise AssertionError('Exact source-size padding did not converge')
    xref = len(prefix) + len(pad_header) + padding + len(pad_footer)
    suffix = pad_footer + trailer(offsets, xref)
    digest = hashlib.sha256()
    with path.open('xb') as output:
        def write(value):
            output.write(value)
            digest.update(value)
        write(prefix)
        write(pad_header)
        block = b'0' * min(padding, MIB)
        remaining = padding
        while remaining:
            take = min(remaining, len(block))
            write(block[:take])
            remaining -= take
        write(suffix)
    size = path.stat().st_size
    assert target_bytes is None or size == target_bytes
    return {'bytes': size, 'sha256': digest.hexdigest(), 'pages': count,
            'padding_stream_bytes': padding, 'decoded_content_command_bytes': decoded_bytes,
            'declared_literal_text_bytes': 256 * 1024 * count if expansion else sum(len(p) for p in pages) if not ocr_pages else 0,
            'ocr_raster_pixels': width * height if ocr_pages else 0}
