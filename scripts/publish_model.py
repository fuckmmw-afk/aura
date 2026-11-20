#!/usr/bin/env python3
"""Lay a Core ML package out for Aura's ModelManager: every file of the package plus manifest.json
(relative path, size, sha256), so the phone fetches plain files and needs no unzip.

    publish_model.py <model.mlpackage> <dest root> <model id> <version>
"""
import hashlib, json, os, shutil, sys

src, root, model_id, version = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
dest = os.path.join(root, model_id)
pkg_name = os.path.basename(src.rstrip("/"))
tmp = dest + ".tmp"
shutil.rmtree(tmp, ignore_errors=True)
shutil.copytree(src, os.path.join(tmp, pkg_name))
files = []
for dirpath, _, names in os.walk(os.path.join(tmp, pkg_name)):
    for n in sorted(names):
        full = os.path.join(dirpath, n)
        rel = os.path.relpath(full, tmp)
        h = hashlib.sha256()
        with open(full, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        files.append({"path": rel, "size": os.path.getsize(full), "sha256": h.hexdigest()})
manifest = {"id": model_id, "version": version, "package": pkg_name,
            "size": sum(f["size"] for f in files), "files": files}
with open(os.path.join(tmp, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=1)
shutil.rmtree(dest, ignore_errors=True)
os.rename(tmp, dest)
print(json.dumps({k: manifest[k] for k in ("id", "version", "package", "size")}))
