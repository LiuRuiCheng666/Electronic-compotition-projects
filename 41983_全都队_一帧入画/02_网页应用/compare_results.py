"""Compare decoded output pixels from the application and original CLI, offline."""
from pathlib import Path
import argparse
import hashlib
import json

import adapters  # Uses the application's bundled image decoder; no device access.
from PIL import Image


def compare(first, second):
    records = []
    for path in (first, second):
        with Image.open(path) as source:
            if getattr(source, "n_frames", 1) != 1:
                raise ValueError("Only single-frame result images can be compared")
            image = source.convert("RGB")
            raw = image.tobytes()
            records.append((image.size, raw, dict(file=str(Path(path).resolve()), width=image.width,
                           height=image.height, rgb_sha256=hashlib.sha256(raw).hexdigest())))
    (size_a, raw_a, record_a), (size_b, raw_b, record_b) = records
    report = dict(status="FAIL", scope="Decoded RGB pixels only; no network or FPGA inference",
                  first=record_a, second=record_b, same_size=size_a == size_b)
    if size_a != size_b:
        report["reason"] = "Result dimensions differ"
        return report
    differing = 0
    first_difference = None
    max_error = 0
    for offset in range(0, len(raw_a), 3):
        a, b = raw_a[offset:offset+3], raw_b[offset:offset+3]
        if a != b:
            differing += 1
            if first_difference is None:
                pixel = offset // 3
                first_difference = dict(x=pixel % size_a[0], y=pixel // size_a[0], first=list(a), second=list(b))
            max_error = max(max_error, *(abs(x-y) for x, y in zip(a, b)))
    report.update(status="PASS" if differing == 0 else "FAIL", differing_pixels=differing,
                  total_pixels=size_a[0]*size_a[1], max_channel_error=max_error, first_difference=first_difference)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_result")
    parser.add_argument("cli_result")
    parser.add_argument("--report")
    args = parser.parse_args()
    if args.report and Path(args.report).resolve() in (Path(args.app_result).resolve(), Path(args.cli_result).resolve()):
        parser.error("Report must not overwrite either input image")
    report = compare(args.app_result, args.cli_result)
    text = json.dumps(report, ensure_ascii=False, indent=2)
    print(text)
    if args.report:
        Path(args.report).write_text(text, encoding="utf-8")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
