import asyncio
import hashlib
import json
import os
import re
import time
import zlib
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
from body_limit import install as install_body_limit
from admission import Admission
from icons import representations
from inline_icons import Icons, PREFIX
from journal import Journal
from policy import domains, pac, tls_pattern, host_pattern

LIMIT = 8 * 1024 * 1024

IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".heic", ".heif",
                                    ".bmp", ".tif", ".tiff", ".ico", ".svg", ".jxl", ".apng")

class Filter:
    def __init__(self):
        self.hosts = set(domains(json.loads(os.environ["FILTER_DOMAINS"])))
        self.inline_icons = Icons()
        self.journal = Journal(images=os.getenv("FILTER_CAPTURE_IMAGES") == "1")
        self.capture = os.getenv("FILTER_CAPTURE") == "1"
        self.token = os.getenv("FILTER_TOKEN","")
        self.scope = (self.hosts, os.environ.get("FILTER_ALL") == "1", json.loads(os.environ.get("FILTER_EXCLUDED","[]")))
        self.rule = re.compile(host_pattern(*self.scope))
        self.counts = {"requests": 0, "scanned": 0, "masked": 0, "errors": 0}
        self.cache = OrderedDict()
        self.admission = Admission()
        self.cost = 0
        self.lock = asyncio.Lock()
        self.worker = None
        self.server = None
        self.parent_watch = None

    def load(self, loader):
        install_body_limit()
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
            if len(first)==3 and first[0] in (b"GET",b"POST"):
                target = urlsplit(first[1].decode("ascii"))
                authorized = self.token and any(hmac.compare_digest(line, b"Authorization: Bearer "+self.token.encode()) for line in headers.split(b"\r\n"))
                if authorized and target.path in ("/events","/export"):
                    export = target.path == "/export"
                    query = parse_qs(target.query)
                    ids = None
                    if first[0] == b"POST":
                        if not export: raise ValueError("Invalid endpoint")
                        length = next((int(line.split(b":",1)[1]) for line in headers.split(b"\r\n")
                                       if line.lower().startswith(b"content-length:")), 0)
                        if not 0 < length <= 65536: raise ValueError("Invalid selection length")
                        selection = json.loads(await asyncio.wait_for(reader.readexactly(length), 3))
                        if not isinstance(selection, list) or not all(isinstance(i,str) for i in selection):
                            raise ValueError("Invalid selection")
                        ids = set(selection)
                    if ids and len(ids) == 1:
                        self.journal.prune()
                        if not any(row["id"] in ids for row, _, _ in self.journal.entries):
                            writer.write(b"HTTP/1.1 410 Gone\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                            await writer.drain()
                            return
                    body = self.journal.report(query.get("site",[""])[0],export,query.get("outcome",["All"])[0],query.get("images",["0"])[0]=="1",ids)
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
            if flow.request.path.startswith(PREFIX):
                if flow.request.method != "GET" or flow.request.headers.get("content-length","0") != "0" or "transfer-encoding" in flow.request.headers:
                    flow.response = http.Response.make(405,b"")
                    return
                origin = f"{flow.request.scheme}://{flow.request.host.lower()}:{flow.request.port}"
                raw = self.inline_icons.get(origin, flow.request.path[len(PREFIX):])
                flow.metadata["localIcon"] = True
                if raw and flow.request.method == "GET":
                    flow.metadata["iconInput"] = raw
                return
            if flow.request.headers.get("sec-fetch-dest") in ("document","iframe","frame"):
                flow.request.headers["accept-encoding"] = "identity"
            if (flow.request.headers.get("sec-fetch-dest") == "image" or
                    flow.request.path.partition("?")[0].lower().endswith(IMAGE_EXTENSIONS)) and flow.request.method == "GET":
                for key in ("if-none-match","if-modified-since","range","if-range"):
                    flow.request.headers.pop(key,None)
                flow.request.headers["accept-encoding"] = "identity"
            flow.request.stream = True

    async def request(self, flow):
        if not flow.metadata.get("localIcon"): return
        raw = flow.metadata.pop("iconInput", None)
        flow.response = http.Response.make(404,b"",{"Cache-Control":"no-store"})
        if not raw: return
        timing = flow.metadata["timing"] = {}
        flow.response = http.Response.make(403,b"",{"Cache-Control":"no-store"})
        if not self.admission.reserve(flow.id, len(raw)):
            if self.capture: self.journal.add(flow,"Blocked · image queue at capacity")
            return
        try:
            settings, payload = self.settings()
            flow.metadata["mask_settings"] = settings
            async with asyncio.timeout(20):
                masked = await self.analyze(raw,payload,timing)
            flow.response = http.Response.make(200, masked or raw, {"Content-Type":"image/png","Cache-Control":"no-store","X-Content-Type-Options":"nosniff"})
            self.counts["scanned"] += 1
            if masked: self.counts["masked"] += 1
            if self.capture: self.journal.add(flow,"Masked" if masked else "Clear",raw,masked)
        except (ValueError,OSError,asyncio.IncompleteReadError,asyncio.TimeoutError) as exc:
            self.counts["errors"] += 1
            flow.metadata["failure"] = type(exc).__name__ + " · " + str(exc)[:180]
            if self.capture: self.journal.add(flow,"Scan error",raw)
        finally:
            self.admission.release(flow.id)

    def responseheaders(self, flow):
        r = flow.response
        kind = r.headers.get("content-type", "").split(";")[0].strip().lower()
        if flow.metadata.get("localIcon"): return
        if "started" in flow.metadata:
            flow.metadata["headersAt"] = time.monotonic()
        # Preflight decisions are carried in status and CORS headers. Serve no payload.
        if flow.request.method == "OPTIONS" and "access-control-request-method" in flow.request.headers:
            r.stream = lambda chunk: b""
            for header in ("content-length", "content-encoding"):
                r.headers.pop(header, None)
            flow.metadata["passVerdict"] = f"CORS preflight HTTP {r.status_code}"
            return
        destination = flow.request.headers.get("sec-fetch-dest", "")
        image_request = destination == "image"
        if self.allowed(flow.request) and not image_request and (kind in ("text/html", "application/xhtml+xml") or
                (kind != "application/pdf" and destination in ("document", "iframe", "frame"))):
            cache_controls = r.headers.get("cache-control","") + "," + flow.request.headers.get("cache-control","")
            editable = (kind == "text/html" and flow.request.method == "GET" and r.status_code == 200
                        and r.headers.get("content-encoding","identity").lower() == "identity"
                        and "no-transform" not in cache_controls.lower() and "content-range" not in r.headers
                        and not any(h in r.headers for h in ("digest","content-digest","repr-digest","signature"))
                        and "'sha" not in r.headers.get("content-security-policy","").lower())
            # Separate policies intersect; retain the site's original security restrictions.
            r.headers.add("content-security-policy", "img-src http: https:")
            r.headers["cache-control"] = "private, no-store"
            if editable:
                for key in ("content-length","content-md5","etag","last-modified","accept-ranges"):
                    r.headers.pop(key,None)
                origin = f"{flow.request.scheme}://{flow.request.host.lower()}:{flow.request.port}"
                r.stream = self.inline_icons.transform(origin)
                return
        path = flow.request.path.split("?", 1)[0].lower()
        image_path = flow.request.method == "GET" and path.endswith(IMAGE_EXTENSIONS)
        ambiguous = kind in ("", "application/octet-stream", "binary/octet-stream")
        candidate = kind.startswith("image/") or image_request or image_path
        if not self.allowed(flow.request) or flow.request.method == "HEAD" or not (candidate or ambiguous):
            r.stream = True
            return
        flow.metadata["ambiguous"] = ambiguous and not candidate
        length = r.headers.get("content-length","")
        encoding = r.headers.get("content-encoding","identity").strip().lower()
        controls = ",".join([r.headers.get("cache-control",""), flow.request.headers.get("cache-control","")])
        restricted = "no-transform" in [v.strip().lower() for v in controls.split(",")]
        flow.metadata["origin"] = dict(status=r.status_code, mime=kind, encoding=encoding,
            declaredLength=length, noTransform=restricted, partial="content-range" in r.headers)
        if r.status_code in (204, 205) or (length == "0" and 200 <= r.status_code < 300):
            r.stream = lambda chunk: b""
            flow.metadata["passVerdict"] = "Empty"
            return
        if r.status_code in (301, 302, 303, 307, 308) and "location" in r.headers:
            # Keep navigation semantics, but drop any uninspected redirect body.
            r.stream = lambda chunk: b""
            for header in ("content-length", "content-encoding", "digest", "content-digest"):
                r.headers.pop(header, None)
            flow.metadata["passVerdict"] = f"Redirect HTTP {r.status_code}"
            return
        reason = None
        acknowledgement = (flow.request.method in ("PUT","POST","PATCH","DELETE") and
                           r.status_code in (200,201,202) and not image_request)
        if (r.status_code != 200 and not acknowledgement) or "content-range" in r.headers: reason = f"incomplete HTTP {r.status_code}"
        elif encoding not in ("identity","gzip","x-gzip","deflate"): reason = "encoding " + encoding
        elif length and (not length.isascii() or not length.isdecimal()): reason = "invalid size"
        elif len(length.lstrip("0")) > 8 or int(length[-8:] or 0) > LIMIT: reason = "over size limit"
        elif not self.admission.reserve(flow.id, int(length[-8:]) if length else LIMIT):
            reason = "image queue at capacity"
        if reason:
            r.stream = lambda chunk: b""
            r.status_code = 403
            for header in ("content-length","content-encoding","content-range","etag","last-modified"):
                r.headers.pop(header,None)
            r.headers["cache-control"] = "no-store"
            r.headers["content-type"] = "text/plain"
            self.counts["blocked"] = self.counts.get("blocked",0)+1
            if self.capture: self.journal.add(flow,"Blocked · "+reason)
            return
        flow.metadata["bufferBudget"] = int(length[-8:]) if length else LIMIT
        r.stream = False
        flow.metadata["scan"] = True

    def settings(self):
        path = os.getenv("FILTER_MASK_FILE")
        settings = json.loads(Path(path).read_text()) if path else {}
        if not isinstance(settings, dict) or not all(isinstance(v, str) for v in settings.values()):
            raise ValueError("Invalid mask settings")
        payload = json.dumps(settings, sort_keys=True, separators=(",", ":")).encode()
        if len(payload) > 4096:
            raise ValueError("Oversized mask settings")
        return settings, payload

    async def analyze(self, body, payload, timing):
        start = time.monotonic()
        digest = hashlib.sha256(body).digest()
        timing["hashMS"] = round(1000 * (time.monotonic() - start))
        start = time.monotonic()
        clear_key = (digest, None)
        key = (digest, payload)
        for cached in (clear_key, key):
            if cached in self.cache:
                self.cache.move_to_end(cached)
                timing["cacheHit"] = True
                return self.cache[cached]
        timing["activeStage"] = "queue"
        async with self.lock:
            timing["activeStage"] = "worker"
            timing["queueMS"] = round(1000 * (time.monotonic() - start))
            for cached in (clear_key, key):
                if cached in self.cache:
                    self.cache.move_to_end(cached)
                    timing.pop("activeStage", None)
                    timing["cacheHit"] = True
                    return self.cache[cached]
            timing["cacheHit"] = False
            started_worker = time.monotonic()
            if self.worker is None or self.worker.returncode is not None:
                self.worker = await asyncio.create_subprocess_exec(os.environ["FILTER_WORKER"],
                    stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,env=dict(os.environ, FILTER_FRAMED_SETTINGS="1", FILTER_WORKER_TIMINGS="1"))
            try:
                async with asyncio.timeout(15):
                    self.worker.stdin.write(struct.pack(">I", len(payload)) + payload)
                    self.worker.stdin.write(struct.pack(">I", len(body)))
                    self.worker.stdin.write(body)
                    await self.worker.stdin.drain()
                    meta_size, = struct.unpack(">I", await self.worker.stdout.readexactly(4))
                    if meta_size > 4096:
                        raise OSError("Invalid worker timing frame")
                    meta = json.loads(await self.worker.stdout.readexactly(meta_size))
                    timing.update(meta.get("stages", {}))
                    size, = struct.unpack(">I", await self.worker.stdout.readexactly(4))
                    if size == 0xffffffff:
                        raise ValueError(meta.get("failure", "Image could not be scanned"))
                    if size > 32*1024*1024:
                        raise OSError("Invalid worker response")
                    result = await self.worker.stdout.readexactly(size)
            except (OSError, asyncio.IncompleteReadError, asyncio.TimeoutError, asyncio.CancelledError):
                if self.worker.returncode is None:
                    self.worker.kill()
                await self.worker.wait()
                self.worker = None
                raise
            timing.pop("activeStage", None)
            timing["workerMS"] = round(1000 * (time.monotonic() - started_worker))
            self.cache[key if result else clear_key] = result
            self.cost += len(result)
            while self.cost > 32*1024*1024 or len(self.cache) > 256:
                self.cost -= len(self.cache.popitem(last=False)[1])
            return result

    async def response(self, flow):
        if not flow.metadata.get("scan"):
            if self.capture and "started" in flow.metadata and not flow.metadata.get("logged"):
                status = flow.response.status_code
                verdict = f"Upstream HTTP {status}" if status >= 400 else "Pass-through"
                self.journal.add(flow, flow.metadata.get("passVerdict", verdict))
            return
        try:
            await self.finish_image(flow)
        finally:
            self.admission.release(flow.id)

    def error(self, flow):
        self.admission.release(flow.id)
        if self.capture and "started" in flow.metadata and not flow.metadata.get("logged"):
            flow.metadata["failure"] = str(flow.error.msg)[:240] if flow.error else "Connection ended"
            self.journal.add(flow, "Transport error")

    async def finish_image(self, flow):
        origin_response = flow.response
        flow.response = http.Response.make(403, b"", {"Cache-Control": "no-store"})
        origin_response.headers["cache-control"] = "private, no-store"
        arrived = time.monotonic()
        timing = flow.metadata["timing"] = {"receiveBodyMS": round(1000 * (arrived-flow.metadata["headersAt"]))}
        raw = origin_response.raw_content
        if raw == b"":
            flow.response = origin_response
            if self.capture: self.journal.add(flow,"Empty")
            return
        if raw is None or len(raw)>LIMIT:
            flow.response = http.Response.make(403,b"",{"Cache-Control":"no-store"})
            if self.capture: self.journal.add(flow,"Blocked · empty or oversized body")
            return
        origin = flow.metadata["origin"]
        try:
            coding = origin["encoding"]
            if coding != "identity":
                decoder = zlib.decompressobj(31 if coding in ("gzip","x-gzip") else 15)
                raw = decoder.decompress(raw,LIMIT+1)
                if not decoder.eof or decoder.unused_data or len(raw)>LIMIT:
                    raise ValueError("Invalid or oversized compressed image")
            # Admit only recognizable raster payloads, independently of CDN MIME labels.
            raster = (raw.startswith((b"\xff\xd8\xff",b"\x89PNG\r\n\x1a\n",b"GIF87a",b"GIF89a",b"BM",
                       b"II*\x00",b"MM\x00*",b"\x00\x00\x01\x00")) or
                      raw[:4]==b"RIFF" and raw[8:12]==b"WEBP" or raw[4:8]==b"ftyp" and
                      any(brand in raw[8:64] for brand in (b"avif",b"heic",b"mif1")))
            if not raster and flow.metadata.get("ambiguous"):
                if len(raw) <= 256 * 1024 and raw.lstrip()[:1] in (b"{", b"["):
                    try:
                        json.loads(raw)
                    except (ValueError, RecursionError):
                        pass
                    else:
                        origin_response.headers["content-type"] = "application/json"
                        origin_response.headers["x-content-type-options"] = "nosniff"
                        flow.response = origin_response
                        if self.capture: self.journal.add(flow, "Pass-through")
                        return
                # Only release recognized non-image containers to a generic binary caller.
                if raw.startswith((b"%PDF-", b"PK\x03\x04", b"\x00asm", b"wOFF", b"wOF2")):
                    flow.response = origin_response
                    if self.capture: self.journal.add(flow, "Pass-through")
                    return
            if not raster:
                flow.response = http.Response.make(403,b"",{"Cache-Control":"no-store"})
                if self.capture: self.journal.add(flow,"Blocked · unsupported payload")
                return
            settings, payload = self.settings()
            flow.metadata["mask_settings"] = settings
            timing["prepareMS"] = round(1000 * (time.monotonic()-arrived))
            async with asyncio.timeout(20):
                for representation in representations(raw):
                    masked = await self.analyze(representation, payload, timing)
                    if masked:
                        break
        except (zlib.error, OSError, ValueError, asyncio.IncompleteReadError, asyncio.TimeoutError) as exc:
            phase = timing.pop("activeStage", "prepare")
            timing["failedAfterMS"] = round(1000 * (time.monotonic()-arrived))
            flow.metadata["failure"] = f"{phase} · {type(exc).__name__} · {str(exc)[:180]}"
            self.counts["errors"] += 1
            flow.response = http.Response.make(403,b"",{"Cache-Control":"no-store"})
            if self.capture: self.journal.add(flow,"Scan error",raw)
            return
        if masked and origin["noTransform"]:
            flow.response = http.Response.make(403,b"",{"Cache-Control":"no-store"})
            self.counts["blocked"] = self.counts.get("blocked",0)+1
            self.counts["scanned"] += 1
            if self.capture: self.journal.add(flow,"Blocked · person in no-transform image",raw)
            return
        self.counts["scanned"] += 1
        if masked:
            self.counts["masked"] += 1
            r = origin_response
            for header in ("content-encoding","etag","last-modified","accept-ranges","digest","content-digest","repr-digest","content-md5"):
                r.headers.pop(header, None)
            r.headers["content-type"] = "image/png"
            r.headers["cache-control"] = "private, no-store"
            r.content = masked
        flow.response = origin_response
        if self.capture: self.journal.add(flow,"Masked" if masked else "Clear",raw,masked)

    def done(self):
        if self.parent_watch:
            self.parent_watch.cancel()
        if self.server:
            self.server.close()
        if self.worker and self.worker.returncode is None:
            self.worker.kill()

addons = [Filter()]
