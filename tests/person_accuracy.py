"""Exercise the packaged worker on labeled product photos, mixed layouts and COCO instance masks.

All fixture downloads are test-only. Report image-level false positives and misses
separately from covered person pixels; a small face patch does not cover a body.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
import statistics
import struct
import subprocess
import time
from zipfile import ZipFile

from PIL import Image, ImageChops, ImageDraw, ImageOps

CASES = Path(__file__).with_name("person-fixtures.json")
COCO = dict(name="coco128-seg.zip",
            url="https://github.com/ultralytics/assets/releases/download/v0.0.0/coco128-seg.zip",
            sha256="8219f78b7d5ec2a164b2f8bca873918c34d275bc94e3bd87cf01b15d97fe1cad")


def download(directory, item):
    path = directory / item["name"]
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
        subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location", "--retry", "3",
                        "--max-time", "60", "-H", "Accept: image/avif,image/webp,image/*,*/*;q=0.8",
                        item["url"], "-o", str(path)], check=True)
    if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
        raise ValueError(f"Fixture changed: {item['name']}. Review the image before updating its label.")


def read_frame(pipe):
    header = pipe.read(4)
    if len(header) != 4:
        raise RuntimeError("Worker exited before verdict")
    size, = struct.unpack(">I", header)
    if size > 32 * 1024 * 1024:
        raise RuntimeError(f"Worker rejected input or emitted an invalid length: {size}")
    data = pipe.read(size)
    if len(data) != size:
        raise RuntimeError("Incomplete worker output")
    return data


@contextmanager
def worker_session(executable):
    settings = dict(os.environ, FILTER_WORKER_TIMINGS="1", FILTER_FRAMED_SETTINGS="1", FILTER_TEST_OBSERVATIONS="1")
    with subprocess.Popen([executable], env=settings, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as proc:
        def scan(data, shape="Silhouette"):
            prefs = json.dumps(dict(FILTER_STYLE="Cover", FILTER_SHAPE=shape,
                                    FILTER_COLOR="FF00FF", FILTER_MARGIN="0")).encode()
            start = time.perf_counter()
            for payload in (prefs, data):
                proc.stdin.write(struct.pack(">I", len(payload)))
                proc.stdin.write(payload)
            proc.stdin.flush()
            meta = json.loads(read_frame(proc.stdout))
            if "failure" in meta:
                raise RuntimeError(meta["failure"])
            body = read_frame(proc.stdout)
            elapsed = (time.perf_counter() - start) * 1000
            if not body:
                return None, meta, elapsed
            pixels = Image.open(BytesIO(body)).convert("RGB")
            r,g,b = pixels.split()
            # Known brightly colored solid treatment makes the emitted mask measurable.
            matte = ImageChops.multiply(ImageChops.multiply(r.point(lambda n:255*(n>=250)),
                     g.point(lambda n:255*(n<=5))), b.point(lambda n:255*(n>=250)))
            return matte, meta, elapsed
        try:
            yield scan
        finally:
            proc.stdin.close()


def encode(image, fmt="PNG"):
    out = BytesIO()
    image.save(out, format=fmt)
    return out.getvalue()


def thumb(raw, edge):
    image = ImageOps.exif_transpose(Image.open(BytesIO(raw))).convert("RGBA")
    image.thumbnail((edge, edge), Image.Resampling.LANCZOS)
    # A retailer may also flatten transparent product art for a JPEG thumbnail.
    base = Image.new("RGB", image.size, "white")
    base.paste(image, mask=image.getchannel("A"))
    return encode(base,"JPEG")


def coverage(matte, box):
    if matte is None:
        return 0.0
    patch = matte.crop(tuple(round(f*n) for f,n in zip(box, matte.size*2)))
    return patch.histogram()[255] / (patch.width*patch.height)


def product_suite(directory, fixtures, portrait, scan):
    errors = []
    negative_count = 0
    for item in fixtures:
        name = item["name"]
        raw = (directory/name).read_bytes()
        if name in ("baby","walk"):
            continue
        sizes = [0] if name == "gallery-3840" else [0,128,256,257]
        for size in sizes:
            matte, meta, _ = scan(thumb(raw,size) if size else raw)
            negative_count += 1
            if matte is not None:
                errors.append(f"{name}@{size or 'source'} falsely masked {matte.getbbox()} {meta.get('recognition')} anchors {meta.get('anchors')}")
    print(f"Empty-product inputs {negative_count}, false masks {len(errors)}",flush=True)
    for name, box in [("baby", (.342,.449,.38,.493)), ("walk",(.16,.22,.31,.38))]:
        raw = (directory/name).read_bytes()
        for size in (0,256):
            matte, meta, _ = scan(thumb(raw,size) if size else raw)
            fraction = coverage(matte,box)
            if name == "walk" and coverage(matte,(.62,.35,.78,.56)) > 0.01:
                errors.append(f"{name}@{size or 'source'} masked the adjacent stroller canopy")
            if fraction < 0.5:
                errors.append(f"{name}@{size or 'source'} only covered {fraction:.0%} of marked face/torso patch ({meta.get('recognition')} anchors {meta.get('anchors')})")
    # A separate piece of merchandise between two portraits must survive even
    # when the person boxes are enlarged to rectangles.
    side = Image.open(portrait).convert("RGB").resize((256,256))
    product = Image.open(directory/"doona-1").convert("RGBA").resize((256,256))
    scene = Image.new("RGB",(768,256),"white")
    scene.paste(side,(0,0))
    scene.paste(product,(256,0),product)
    scene.paste(side,(512,0))
    for shape in ("Silhouette","Rectangle"):
        matte, _, _ = scan(encode(scene),shape)
        if not matte or matte.crop((270,0,498,256)).getbbox():
            errors.append(f"{shape}: missing people or mask leaked between them")
        for x in (0,512):
            if coverage(matte, ((x+101)/768, 42/256, (x+122)/768, 62/256)) < 0.85:
                errors.append(f"{shape}: insufficient coverage on portrait at {x}")
    return errors


def coco_suite(path, scan, build_label):
    counts = Counter()
    latency = []
    detail = []
    with ZipFile(path) as archive:
        members = set(archive.namelist())
        for name in sorted(n for n in members if n.endswith(".jpg") and "/images/" in n and "/." not in n):
            raw = archive.read(name)
            w,h = Image.open(BytesIO(raw)).size
            truth = Image.new("L",(w,h))
            label = name.replace("/images/","/labels/").replace(".jpg",".txt")
            polygons = []
            for line in archive.read(label).decode().splitlines() if label in members else []:
                fields = line.split()
                if fields[0] == "0":
                    coords = list(map(float,fields[1:]))
                    polygons.append([(x*w,y*h) for x,y in zip(coords[::2],coords[1::2])])
            for poly in polygons: ImageDraw.Draw(truth).polygon(poly,fill=255)
            matte, meta, ms = scan(raw)
            latency.append(ms)
            counts[("TP" if matte is not None else "FN") if polygons else ("FP" if matte is not None else "TN")] += 1
            annotated = truth.histogram()[255]
            shaded = 0 if matte is None else matte.histogram()[255]
            correct = 0 if matte is None else ImageChops.multiply(truth,matte).histogram()[255]
            counts["personPixels"] += annotated
            counts["maskedPixels"] += shaded
            counts["correctPixels"] += correct
            person_coverage = []
            for poly in polygons:
                instance = Image.new("L",(w,h))
                ImageDraw.Draw(instance).polygon(poly,fill=255)
                fraction = 0 if matte is None else ImageChops.multiply(instance,matte).histogram()[255]/max(1,instance.histogram()[255])
                person_coverage.append(round(fraction,3))
                counts["instances"] += 1
                counts["halfCovered"] += fraction >= 0.5
            detail.append(dict(image=Path(name).name, referencePixels=annotated, coveredPixels=shaded,
                               correctPixels=correct, personCoverage=person_coverage,
                               recognition=meta.get("recognition"), workerMS=round(ms,1)))
    if output := os.getenv("FILTER_TEST_EVIDENCE"):
        folder = Path(output)
        folder.mkdir(parents=True,exist_ok=True)
        (folder/f"person-accuracy{'-reference' if build_label == 'preview145' else ''}.json").write_text(json.dumps({"counts":dict(counts),"images":detail},indent=2))
    assert len(latency) == 128
    print("COCO128-seg",build_label,dict(counts),"pixel precision",round(counts["correctPixels"]/max(1,counts["maskedPixels"]),3),
          "pixel recall",round(counts["correctPixels"]/counts["personPixels"],3),
          "median worker ms",round(statistics.median(latency),1),flush=True)
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("worker",type=Path)
    parser.add_argument("fixture_directory",type=Path)
    parser.add_argument("portrait",type=Path)
    parser.add_argument("--reference-worker",type=Path,help="Pinned preview 145 worker built for the same Mac")
    args = parser.parse_args()
    fixtures = json.loads(CASES.read_text())
    args.fixture_directory.mkdir(parents=True,exist_ok=True)
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda item: download(args.fixture_directory,item), [*fixtures,COCO]))
    reference = None
    if args.reference_worker:
        with worker_session(args.reference_worker) as scan:
            print("Reference worker, preview 145",flush=True)
            product_suite(args.fixture_directory,fixtures,args.portrait,scan)
            reference = coco_suite(args.fixture_directory/COCO["name"],scan,"preview145")
    print("Candidate worker",flush=True)
    with worker_session(args.worker) as scan:
        errors = product_suite(args.fixture_directory,fixtures,args.portrait,scan)
        for error in errors: print("REGRESSION",error,flush=True)
        counts = coco_suite(args.fixture_directory/COCO["name"],scan,"candidate")
        minimum_detections = reference["TP"] if reference is not None else 52
        maximum_false = min(6,reference["FP"]) if reference is not None else 6
        minimum_recall = reference["correctPixels"]/reference["personPixels"]-0.025 if reference is not None else 0.89
        if counts["TP"] < minimum_detections or counts["FP"] > maximum_false:
            errors.append("COCO image-level recall or false-positive budget failed")
        if (counts["correctPixels"] / max(1,counts["maskedPixels"]) < 0.72 or
            counts["correctPixels"] / counts["personPixels"] < minimum_recall):
            errors.append("COCO pixel-level precision or coverage budget failed")
    if errors:
        raise SystemExit(f"{len(errors)} accuracy regressions: " + " | ".join(errors))


if __name__ == "__main__": main()
