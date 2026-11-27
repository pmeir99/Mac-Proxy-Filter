"""Extract self-contained ICO representations so every selectable image is scanned."""
import struct


def representations(data):
    if not data.startswith(b"\x00\x00\x01\x00"):
        return [data]
    if len(data) < 6:
        raise ValueError("Incomplete icon header")
    count, = struct.unpack_from("<H", data, 4)
    end = 6 + count * 16
    if not 1 <= count <= 32 or len(data) < end:
        raise ValueError("Invalid icon directory")
    entries = []
    for i in range(count):
        entry = data[6+16*i:22+16*i]
        length, offset = struct.unpack_from("<II", entry, 8)
        if offset < end or not length or offset + length > len(data):
            raise ValueError("Invalid icon representation")
        area = (entry[0] or 256) * (entry[1] or 256)
        entries.append((area, offset, length, entry))
    if count == 1:
        return [data]

    def images():
        for _, offset, length, entry in sorted(entries, reverse=True):
            body = data[offset:offset+length]
            if body.startswith(b"\x89PNG\r\n\x1a\n"):
                yield body
            else:
                yield b"\x00\x00\x01\x00\x01\x00" + entry[:12] + struct.pack("<I", 22) + body
    return images()
