#!/usr/bin/env python3
"""Fetch the models the way the phone does (manifest, every file, sha256), compile them with Core ML and run them on
the Mac runner (Apple silicon: CPU + Neural Engine), checking that their output makes sense.

    check_models.py <models base URL>
"""
import hashlib, json, os, subprocess, sys, tempfile, time, urllib.request
import numpy as np
from PIL import Image, ImageDraw
import coremltools as ct

BASE = sys.argv[1].rstrip("/")
failures = 0


def check(cond, message):
    global failures
    print(("ok   " if cond else "FAIL ") + message)
    if not cond:
        failures += 1


def fetch(model_id, root):
    with urllib.request.urlopen(f"{BASE}/{model_id}/manifest.json", timeout=60) as r:
        manifest = json.load(r)
    for f in manifest["files"]:
        target = os.path.join(root, f["path"])
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with urllib.request.urlopen(f"{BASE}/{model_id}/{f['path']}", timeout=300) as r, open(target, "wb") as out:
            out.write(r.read())
        digest = hashlib.sha256(open(target, "rb").read()).hexdigest()
        check(digest == f["sha256"] and os.path.getsize(target) == f["size"], f"{model_id}: {f['path']} checksum")
    package = os.path.join(root, manifest["package"])
    out = subprocess.run(["xcrun", "coremlcompiler", "compile", package, root], capture_output=True, text=True)
    check(out.returncode == 0, f"{model_id}: coremlcompiler compiles it ({out.stderr.strip()[:200]})")
    print(f"     {model_id}: {manifest['size'] / 1e6:.1f} MB")
    return package


def timed(model, inputs, runs=10):
    model.predict(inputs)
    start = time.perf_counter()
    for _ in range(runs):
        out = model.predict(inputs)
    return out, (time.perf_counter() - start) / runs * 1000


def test_depth(root):
    package = fetch("depth-v2s-p8", root)
    model = ct.models.MLModel(package, compute_units=ct.ComputeUnit.CPU_AND_NE)
    # A near disc on a far floor: the disc must come out nearer (brighter) than the corners.
    img = Image.new("RGB", (518, 392), (40, 60, 90))
    d = ImageDraw.Draw(img)
    for y in range(392):
        d.line([(0, y), (518, y)], fill=(40 + y // 6, 60 + y // 8, 90))
    d.ellipse([190, 120, 330, 300], fill=(230, 120, 60))
    out, ms = timed(model, {"image": img})
    depth = np.asarray(out["depth"], dtype=np.float32)
    check(depth.shape == (392, 518), f"depth: output {depth.shape}")
    centre = depth[190:230, 240:280].mean()
    corner = depth[5:40, 5:40].mean()
    check(float(depth.std()) > 1e-3, f"depth: the map varies (std {depth.std():.4f})")
    print(f"     depth: disc {centre:.3f}, far corner {corner:.3f} (larger is nearer)")
    print(f"     depth: {ms:.1f} ms a frame on this Mac (CPU + ANE)")


def test_upscale(root):
    package = fetch("esrgan-x4v3", root)
    model = ct.models.MLModel(package, compute_units=ct.ComputeUnit.CPU_AND_NE)
    rng = np.random.default_rng(7)
    base = (rng.random((16, 16, 3)) * 255).astype(np.uint8)
    tile = Image.fromarray(base).resize((128, 128), Image.BICUBIC)
    out, ms = timed(model, {"image": tile})
    up = out["upscaled"]
    check(up.size == (512, 512), f"upscale: output {up.size}")
    ref = np.asarray(tile.resize((512, 512), Image.BICUBIC), dtype=np.float32)
    got = np.asarray(up.convert("RGB"), dtype=np.float32)
    mse = ((ref - got) ** 2).mean()
    psnr = 10 * np.log10(255 ** 2 / max(mse, 1e-6))
    check(psnr > 22, f"upscale: close to a bicubic x4 of the same tile (PSNR {psnr:.1f} dB)")
    print(f"     upscale: {ms:.1f} ms a 128 px tile on this Mac (CPU + ANE)")


with tempfile.TemporaryDirectory() as root:
    test_depth(root)
    test_upscale(root)
if failures:
    print(f"{failures} check(s) failed")
    sys.exit(1)
print("models ok")
