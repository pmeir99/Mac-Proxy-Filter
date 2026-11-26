import asyncio
import hashlib
import json
import os
import re
import time
import hmac
from urllib.parse import urlsplit, parse_qs
import struct
import sys
from collections import OrderedDict
from pathlib import Path
from mitmproxy import ctx, http

# Keep imports from creating files inside the signed app bundle.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from journal import Journal
from policy import domains, pac, tls_pattern, host_pattern

LIMIT = 8 * 1024 * 1024
TYPES = {"image/jpeg", "image/png", "image/webp", "image/avif"}

class Filter:
    def __init__(self):
        self.hosts = set(domains(json.loads(os.environ["FILTER_DOMAINS"])))
        self.journal = Journal()
        self.capture = os.getenv("FILTER_CAPTURE") == "1"
        self.token = os.getenv("FILTER_TOKEN","")
        self.scope = (self.hosts, os.environ.get("FILTER_ALL") == "1", json.loads(os.environ.get("FILTER_EXCLUDED","[]")))
        self.rule = re.compile(host_pattern(*self.scope))
        self.counts = {"requests": 0, "scanned": 0, "masked": 0, "errors": 0}
        self.cache = OrderedDict()
        self.style = None
        self.cost = 0
        self.lock = asyncio.Lock()
        self.worker = None
        self.server = None
        self.parent_watch = None

    def load(self, loader):
        ctx.options.update(allow_hosts=[tls_pattern(*self.scope)])

    async def running(self):
        try:
            self.server = await asyncio.start_server(self.serve_pac, "127.0.0.1", 17861, limit=4096)
            if "FILTER_PARENT_PID" in os.environ:
                self.parent_watch = asyncio.create_task(self.watch_parent(int(os.environ["FILTER_PARENT_PID"])))
            Path(os.environ["FILTER_READY"]).write_text("ready")
        except OSError:
            ctx.master.shutdown()

    async def watch_parent(self, parent):
        while True:
            try:
                os.kill(parent, 0)
            except ProcessLookupError:
                ctx.master.shutdown()
                return
            self.journal.prune()
            await asyncio.sleep(1)

    async def serve_pac(self, reader, writer):
        try:
            headers = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 2)
            parts = headers.split(b"\r\n",1)[0].split()
            valid = len(parts)==3 and parts[0]==b"GET" and parts[1].split(b"?",1)[0]==b"/proxy.pac"
            status, body = ("200 OK", pac(*self.scope).encode()) if valid else ("404 Not Found", b"")
            if headers.split(b"\r\n", 1)[0] == b"GET /status HTTP/1.1":
                status, body = "200 OK", json.dumps(self.counts).encode()
            mime = "application/x-ns-proxy-autoconfig" if valid else "application/json"
            first = headers.split(b"\r\n",1)[0].split(b" ")
            if len(first)==3 and first[0]==b"GET":
                target = urlsplit(first[1].decode("ascii"))
                authorized = self.token and any(hmac.compare_digest(line, b"Authorization: Bearer "+self.token.encode()) for line in headers.split(b"\r\n"))
                if authorized and target.path in ("/events","/export"):
                    export = target.path == "/export"
                    body = self.journal.report(parse_qs(target.query).get("site",[""])[0],export)
                    status = "200 OK"
                    mime = "application/zip" if export else "application/json"
            writer.write((f"HTTP/1.1 {status}\r\nContent-Type: {mime}\r\n"
                          f"Cache-Control: no-store\r\nConnection: close\r\nContent-Length: {len(body)}\r\n\r\n").encode()+body)
            await writer.drain()
        except (OSError, asyncio.TimeoutError, ValueError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            pass
        finally:
            writer.close()

    def allowed(self, req):
        return bool(self.rule.fullmatch(req.host.lower().rstrip("."))) and 1 <= req.port <= 65535

    def http_connect(self, flow):
        if not self.allowed(flow.request):
            flow.response = http.Response.make(403, b"Outside configured domains")

    def requestheaders(self, flow):
        if not self.allowed(flow.request):
            flow.response = http.Response.make(403, b"Outside configured domains")
        else:
            flow.metadata["started"] = time.monotonic()
            self.counts["requests"] += 1
            if flow.request.headers.get("sec-fetch-dest") == "image":
                for key in ("if-none-match","if-modified-since","range","if-range"):
                    flow.request.headers.pop(key,None)
                flow.request.headers["accept-encoding"] = "identity"
            flow.request.stream = True

    def responseheaders(self, flow):
        r = flow.response
        kind = r.headers.get("content-type", "").split(";")[0].strip().lower()
        transform = (self.allowed(flow.request) and flow.request.method == "GET" and r.status_code == 200
                     and (kind in TYPES or (kind in ("","application/octet-stream","binary/octet-stream") and flow.request.headers.get("sec-fetch-dest") == "image")) and not r.headers.get("content-range")
                     and r.headers.get("content-encoding","identity").lower() == "identity"
                     and "no-transform" not in (r.headers.get("cache-control","")+","+flow.request.headers.get("cache-control","")).lower())
        length = r.headers.get("content-length", "")
        if not transform or not length.isdecimal() or not 0 < int(length) <= LIMIT:
            original_status = r.status_code
            r.stream = True
            if (self.allowed(flow.request) and flow.request.method=="GET" and
                (kind.startswith("image/") or flow.request.headers.get("sec-fetch-dest")=="image") and
                (200 <= r.status_code < 300 or r.status_code==304)):
                # Suppress every upstream byte, including the first progressive image chunk.
                r.stream = lambda chunk: b""
                r.status_code = 403
                for key in ("content-length","content-encoding","content-range","etag","last-modified"):
                    r.headers.pop(key,None)
                r.headers["cache-control"] = "no-store"
                r.headers["content-type"] = "text/plain"
                self.counts["blocked"] = self.counts.get("blocked",0)+1
            if self.capture and (kind.startswith("image/") or flow.request.headers.get("sec-fetch-dest") == "image"):
                if original_status != 200: reason = f"HTTP {original_status}"
                elif kind not in TYPES: reason = "media type"
                elif not length.isdecimal(): reason = "unknown size"
                elif int(length) > LIMIT: reason = "over size limit"
                elif r.headers.get("content-encoding","identity").lower() != "identity": reason = "content encoding"
                else: reason = "response policy"
                self.journal.add(flow,("Blocked · " if r.status_code==403 and original_status!=403 else "Skipped · ")+reason)
        else:
            flow.metadata["scan"] = True

    async def analyze(self, body):
        key = hashlib.sha256(body).digest()
        def settings():
            path = os.getenv("FILTER_MASK_FILE")
            return tuple(sorted(json.loads(Path(path).read_text()).items())) if path else ()
        style = settings()
        if self.style == style and key in self.cache:
            self.cache.move_to_end(key)
            return self.cache[key]
        async with self.lock:
            style = settings()
            if style != self.style:
                if self.worker and self.worker.returncode is None:
                    self.worker.terminate()
                    await self.worker.wait()
                self.worker = None
                self.cache.clear()
                self.cost = 0
                self.style = style
            if key in self.cache:
                self.cache.move_to_end(key)
                return self.cache[key]
            if self.worker is None or self.worker.returncode is not None:
                self.worker = await asyncio.create_subprocess_exec(os.environ["FILTER_WORKER"],
                    stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,env=dict(os.environ,**dict(style)))
            try:
                async with asyncio.timeout(15):
                    self.worker.stdin.write(struct.pack(">I", len(body))+body)
                    await self.worker.stdin.drain()
                    size, = struct.unpack(">I", await self.worker.stdout.readexactly(4))
                    if size == 0xffffffff:
                        raise ValueError("Image could not be scanned")
                    if size > 32*1024*1024:
                        raise OSError("Invalid worker response")
                    result = await self.worker.stdout.readexactly(size)
            except (OSError, asyncio.IncompleteReadError, asyncio.TimeoutError, asyncio.CancelledError):
                if self.worker.returncode is None:
                    self.worker.kill()
                await self.worker.wait()
                self.worker = None
                raise
            self.cache[key] = result
            self.cost += len(result)
            while self.cost > 32*1024*1024 or len(self.cache) > 256:
                self.cost -= len(self.cache.popitem(last=False)[1])
            return result

    async def response(self, flow):
        if not flow.metadata.get("scan"):
            return
        flow.response.headers["cache-control"] = "private, no-store"
        raw = flow.response.raw_content
        if not raw or len(raw)>LIMIT:
            flow.response = http.Response.make(403,b"",{"Cache-Control":"no-store"})
            return
        kind = flow.response.headers.get("content-type","").split(";")[0].strip().lower()
        if kind not in TYPES and not (raw.startswith((b"\xff\xd8\xff", b"\x89PNG\r\n\x1a\n")) or
                raw[:4] == b"RIFF" and raw[8:12] == b"WEBP" or raw[4:12] == b"ftypavif"):
            if self.capture: self.journal.add(flow,"Blocked: unsupported")
            flow.response = http.Response.make(403,b"",{"Cache-Control":"no-store"})
            return
        try:
            masked = await self.analyze(raw)
            flow.metadata["mask_settings"] = dict(self.style or ())
        except (OSError, ValueError, asyncio.IncompleteReadError, asyncio.TimeoutError):
            if self.capture: self.journal.add(flow,"Blocked: scan error",raw)
            self.counts["errors"] += 1
            flow.response = http.Response.make(403,b"",{"Cache-Control":"no-store"})
            return
        if self.capture: self.journal.add(flow,"Masked" if masked else "Clear",raw,masked)
        self.counts["scanned"] += 1
        if masked:
            self.counts["masked"] += 1
            r = flow.response
            for header in ("etag","last-modified","accept-ranges","digest","content-digest","repr-digest","content-md5"):
                r.headers.pop(header, None)
            r.headers["content-type"] = "image/png"
            r.headers["cache-control"] = "private, no-store"
            r.content = masked

    def done(self):
        if self.parent_watch:
            self.parent_watch.cancel()
        if self.server:
            self.server.close()
        if self.worker and self.worker.returncode is None:
            self.worker.kill()

addons = [Filter()]
