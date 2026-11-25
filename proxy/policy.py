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

def pac(hosts):
    return """function FindProxyForURL(url, host) {
  host = host.toLowerCase().replace(/\\.$/, "");
  var domains = %s;
  if (!/^https?:/i.test(url)) return "DIRECT";
  return domains.indexOf(host) >= 0 ? "PROXY 127.0.0.1:17862" : "DIRECT";
}""" % json.dumps(domains(hosts))

def tls_pattern(hosts):
    names = "|".join(re.escape(host) for host in domains(hosts))
    return r"(?i)^(?:" + (names or "(?!)") + r")\.?:(?:443|80)$"
