"""Measure the installed worker with a private, labeled local image corpus."""
import argparse
import csv
import math
from pathlib import Path
import statistics
import struct
import subprocess
import time

MAX_INPUT = 8 * 1024 * 1024


def exchange(process, image):
    process.stdin.write(struct.pack(">I", len(image)))
    process.stdin.write(image)
    process.stdin.flush()
    header = process.stdout.read(4)
    if len(header) != 4:
        raise RuntimeError("Worker stopped before returning a verdict")
    length, = struct.unpack(">I", header)
    if length == 0xffffffff:
        return "error"
    if length > 32 * 1024 * 1024 or len(process.stdout.read(length)) != length:
        raise RuntimeError("Invalid worker response")
    return "people" if length else "clear"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path, help="Directory containing people/ and clear/ subdirectories")
    parser.add_argument("output", type=Path, help="New CSV file for individual results")
    parser.add_argument("--worker", type=Path, default=Path("/Applications/Mac Proxy Filter.app/Contents/MacOS/MaskWorker"))
    args = parser.parse_args()
    samples = []
    for label in ("people", "clear"):
        files = sorted(p for p in (args.corpus / label).glob("*") if p.is_file() and not p.name.startswith("."))
        if not files:
            parser.error(f"Missing labeled images in {label}/")
        samples.extend((p, label) for p in files)
    timings = []
    mistakes = 0
    with args.output.open("x", newline="") as output:
        rows = csv.writer(output)
        rows.writerow(("file", "expected", "actual", "worker_ms", "pass"))
        with subprocess.Popen([args.worker], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as worker:
            try:
                for iteration in range(2):
                    for path, label in samples:
                        if not 0 < path.stat().st_size <= MAX_INPUT:
                            raise ValueError(f"Image outside worker size limits: {path.name}")
                        image = path.read_bytes()
                        start = time.perf_counter()
                        actual = exchange(worker, image)
                        elapsed = (time.perf_counter() - start) * 1000
                        rows.writerow((path.name, label, actual, round(elapsed, 2), iteration + 1))
                        if iteration:
                            timings.append(elapsed)
                            mistakes += actual != label
            finally:
                worker.stdin.close()
                worker.terminate()
    p95 = sorted(timings)[math.ceil(0.95 * len(timings)) - 1]
    print(f"Second pass: {len(timings)} images, {mistakes} disagreements/errors, median {statistics.median(timings):.1f} ms, p95 {p95:.1f} ms")


if __name__ == "__main__":
    main()
