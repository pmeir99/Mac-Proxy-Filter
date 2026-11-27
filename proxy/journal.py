"""Five-minute, bounded in-memory diagnostic capture."""
from collections import deque
from io import BytesIO
import json
import time
from urllib.parse import urlsplit
from uuid import uuid4
from zipfile import ZipFile

class Journal:
    def __init__(self, images=False):
        self.images = images
        self.entries = deque()
        self.size = 0

    def prune(self):
        while self.entries and (self.entries[0][0]["time"] < time.time()-300 or
                self.size > 64*1024*1024 or len(self.entries) > 1500):
            _, before, after = self.entries.popleft()
            self.size -= len(before) + len(after)

    def add(self, flow, verdict, before=b"", after=b""):
        flow.metadata["logged"] = True
        response = flow.response
        try:
            site = urlsplit(flow.request.headers.get("referer", "")).hostname or ""
        except ValueError:
            site = ""
        row = dict(id=uuid4().hex, time=time.time(), site=site, host=flow.request.host,
                   verdict=verdict, mime=response.headers.get("content-type","").split(";")[0] if response else "",
                   status=response.status_code if response else 0, elapsedMS=round((time.monotonic()-flow.metadata.get("started",time.monotonic()))*1000),
                   beforeBytes=len(before), afterBytes=len(after or before))
        outcome = ("Error" if "error" in verdict.lower() else "Blocked" if verdict.startswith("Blocked")
                   else verdict if verdict in ("Masked","Clear") else "Upstream")
        row["outcome"] = outcome
        row["method"] = flow.request.method
        if "failure" in flow.metadata: row["failure"] = flow.metadata["failure"]
        processing = dict(flow.metadata.get("timing", {}))
        if "headersAt" in flow.metadata:
            processing["waitHeadersMS"] = round(1000 * (flow.metadata["headersAt"] - flow.metadata["started"]))
        if "cacheHit" in processing: row["cacheHit"] = processing.pop("cacheHit")
        row["processing"] = processing
        if "origin" in flow.metadata:
            row["origin"] = flow.metadata["origin"]
            row["mime"] = row["origin"]["mime"]
        if "mask_settings" in flow.metadata: row["maskSettings"] = flow.metadata["mask_settings"]
        if outcome in ("Error","Blocked"): row["afterBytes"] = 0
        if not self.images: before = after = b""
        self.entries.append((row,before,after))
        self.size += len(before)+len(after)
        self.prune()

    def report(self, site, archive, outcome="All", images=False):
        self.prune()
        entries=[e for e in self.entries if not site or site.lower() in (e[0]["site"].lower(),e[0]["host"].lower())]
        entries = [e for e in entries if outcome == "All" or e[0]["outcome"] == outcome]
        if not archive:
            return json.dumps([e[0] for e in reversed(entries)]).encode()
        data=BytesIO()
        rows=[]
        with ZipFile(data,"w") as zip:
            for row,before,after in entries:
                record=dict(row)
                if images and before:
                    ext={"image/jpeg":"jpg","image/png":"png","image/webp":"webp","image/avif":"avif"}.get(row["mime"],"bin")
                    record["before"]=f'images/{row["id"]}-before.{ext}'
                    zip.writestr(record["before"],before)
                    if row["afterBytes"]: record["after"]=record["before"]
                    if after:
                        record["after"]=f'images/{row["id"]}-after.png'
                        zip.writestr(record["after"],after)
                rows.append(record)
            zip.writestr("mask-settings.json", json.dumps(
                {row["id"]: row["maskSettings"] for row in rows if "maskSettings" in row}, indent=2))
            zip.writestr("manifest.json",json.dumps(rows,indent=2))
        return data.getvalue()
