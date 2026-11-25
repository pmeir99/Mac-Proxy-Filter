import os
import sys
import re
from pathlib import Path
import unittest
import subprocess
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"proxy"))
from policy import domains, pac, tls_pattern

class PolicyTest(unittest.TestCase):
    def test_invalid(self):
        for name in ("*", "127.0.0.1", "a..com", "localhost", "foo.com/a", "foo.com:443","https://foo.example"):
            with self.assertRaises(ValueError):
                domains([name])

    def test_routes(self):
        selected=[" Media.Example.COM ", "media.example.com"]
        self.assertEqual(domains(selected),["media.example.com"])
        for host, enabled in [("media.example.com",True),("media.example.com.",True),
                              ("other.media.example.com",False),("media.example.com.evil.test",False)]:
            result=subprocess.check_output(["node","-e",pac(selected)+f'\nconsole.log(FindProxyForURL("https://x/", "{host}"))'],text=True).strip()
            self.assertEqual(result.startswith("PROXY"),enabled)
            self.assertEqual(bool(re.fullmatch(tls_pattern(selected),host+":443")),enabled)
        self.assertFalse(re.fullmatch(tls_pattern([]),"example.org:443"))

if __name__=="__main__":
    unittest.main()
