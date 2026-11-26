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
        for url, expected in [("https://media.example.com:8080/", "PROXY 127.0.0.1:17862; DIRECT"), ("ftp://media.example.com/", "DIRECT")]:
            js = pac(selected) + f'\nconsole.log(FindProxyForURL("{url}", "media.example.com"))'
            self.assertEqual(subprocess.check_output(["node", "-e", js], text=True).strip(), expected)
        self.assertFalse(re.fullmatch(tls_pattern([]),"example.org:443"))

    def test_all_sites(self):
        scope = ([], True, ["skip.example"])
        for host, active in [("shop.example", True), ("cdn.shop.example", True), ("skip.example", False),
                             ("printer.local", False), ("localhost", False), ("127.0.0.1", False)]:
            js = pac(*scope) + f'\nconsole.log(FindProxyForURL("https://{host}/", "{host}"))'
            self.assertEqual(subprocess.check_output(["node","-e",js],text=True).startswith("PROXY"), active)
            self.assertEqual(bool(re.fullmatch(tls_pattern(*scope),host+":443")), active)

if __name__=="__main__":
    unittest.main()
