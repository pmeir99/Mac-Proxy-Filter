"""Replace small quoted inline PNG sources with same-origin, locally scanned URLs."""
import base64
from collections import OrderedDict
import re
import secrets
import struct
import time

PREFIX = "/.well-known/mac-proxy-filter/icon/"
START = re.compile(rb"""(["'])data:image/png;base64,""", re.I)
MAX_LITERAL = 16384


class Icons:
    def __init__(self):
        self.items = OrderedDict()

    def save(self, origin, raw):
        token = secrets.token_urlsafe(18)
        self.items[token] = (origin, raw, time.monotonic())
        while len(self.items) > 512:
            self.items.popitem(last=False)
        return (origin + PREFIX + token).encode("ascii")

    def get(self, origin, token):
        entry = self.items.get(token)
        if entry and entry[0] == origin and time.monotonic() - entry[2] <= 300:
            return entry[1]
        return None

    def transform(self, origin):
        tail = b""
        def chunks(chunk):
            nonlocal tail
            data = tail + chunk
            tail = b""
            pos = 0
            output = bytearray()
            while match := START.search(data, pos):
                output.extend(data[pos:match.start()])
                start = match.end()
                quote = match[1]
                end = data.find(quote, start, start + MAX_LITERAL + 1)
                if end < 0:
                    if chunk and len(data)-start <= MAX_LITERAL:
                        tail = data[match.start():]
                        return bytes(output)
                    output.extend(data[match.start():start])
                    pos = start
                    continue
                literal = data[start:end]
                try:
                    # JavaScript string literals commonly escape Base64 padding.
                    encoded = re.sub(rb"\\(?:x3[dD]|u003[dD])", b"=", literal)
                    encoded = encoded.replace(b"\\/", b"/")
                    raw = base64.b64decode(encoded, validate=True)
                    if raw[:16] != b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR":
                        raise ValueError()
                    w,h = struct.unpack(">II",raw[16:24])
                    if not (0 < w <= 64 and 0 < h <= 64): raise ValueError()
                    output.extend(quote + self.save(origin,raw) + quote)
                except (ValueError, struct.error):
                    output.extend(data[match.start():end+1])
                pos = end+1
            rest = data[pos:]
            # Keep enough bytes to catch a prefix split across network chunks.
            keep = min(len(rest), 24) if chunk else 0
            if keep:
                tail = rest[-keep:]
                rest = rest[:-keep]
            output.extend(rest)
            return bytes(output)
        return chunks
