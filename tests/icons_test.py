import base64
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"proxy"))
from inline_icons import Icons, PREFIX


class IconStreamTest(unittest.TestCase):
    def test_chunk_boundaries_and_origin(self):
        origin = "https://search.example:443"
        icons = Icons()
        raw = bytes.fromhex("89504e470d0a1a0a0000000d49484452")+struct.pack(">II", 32, 32)+b"X"
        encoded = base64.b64encode(raw).replace(b"=",br"\x3d")
        literal = b"'data:image/png;base64," + encoded + b"'"
        for split in range(len(literal)+1):
            stream = icons.transform(origin)
            out = b"".join(stream(chunk) for chunk in (literal[:split],literal[split:]) if chunk) + stream(b"")
            url = out.decode()[1:-1]
            self.assertTrue(url.startswith(origin + PREFIX))
            token = url.split("/")[-1]
            self.assertEqual(icons.get(origin,token),raw)
            self.assertIsNone(icons.get("https://other.example",token))


if __name__=="__main__":
    unittest.main()
