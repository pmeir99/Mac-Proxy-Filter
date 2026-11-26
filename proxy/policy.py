"""Destination scope shared by the PAC and TLS/HTTP gates."""
import json
import re

LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")

def domains(values):
    result = set()
    for value in values:
        host = value.strip().lower().rstrip(".")
        if not host:
            continue
        parts = host.split(".")
        if (len(host) > 253 or len(parts) < 2 or parts[-1].isdecimal()
                or not all(LABEL.fullmatch(part) for part in parts)):
            raise ValueError("Enter DNS names, one per line. Use ASCII or punycode.")
        result.add(host)
    return sorted(result)

# All-sites mode applies to public-style DNS names. Local hosts and IP literals stay direct.
PUBLIC = r"(?![a-z0-9.-]*\.(?:localhost|local|internal|home\.arpa)\.?$)(?:[a-z0-9-]+\.)+[a-z][a-z0-9-]*"
def host_pattern(hosts, all_sites=False, excluded=()):
    block = "|".join(re.escape(h) for h in domains(excluded))
    pattern = PUBLIC if all_sites else "|".join(re.escape(h) for h in domains(hosts)) or "(?!)"
    return "^" + ("(?!(?:" + block + ")$)" if block else "") + "(?:" + pattern + ")$"

def pac(hosts, all_sites=False, excluded=()):
    return r"""function FindProxyForURL(url, host) {
  host = host.toLowerCase().replace(/\.$/, "");
  if (!/^https?:/i.test(url)) return "DIRECT";
  return new RegExp(%s).test(host) ? "PROXY 127.0.0.1:17862; DIRECT" : "DIRECT";
}""" % json.dumps(host_pattern(hosts, all_sites, excluded))

def tls_pattern(hosts, all_sites=False, excluded=()):
    # Adapt end-of-host assertions to mitmproxy's host:port representation.
    body = host_pattern(hosts, all_sites, excluded).replace("$", r"(?=\.?:[0-9]+$)")
    return "(?i)" + body + r"\.?:[0-9]+$"
