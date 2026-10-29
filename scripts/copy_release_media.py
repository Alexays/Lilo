#!/usr/bin/env python3
"""Copy only the current release's approved binary media, outside the text UI embed."""
import hashlib
import json
import pathlib
import os
import re
import shutil

root = pathlib.Path(__file__).resolve().parent.parent
version = os.environ.get("LILO_RELEASE_PREVIEW") or json.loads((root / "lilo-ui/package.json").read_text())["version"]
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise ValueError("Invalid release preview version")
source = root / "site/src/assets/releases" / version
target = root / "lilo-ui/public/release-media"
target.mkdir(parents=True, exist_ok=True)
manifest = source / "capture.json"
archive = json.loads(manifest.read_text()) if manifest.exists() and os.environ.get("LILO_CAPTURE_BUILD") != "1" else {}
wanted = set()
presentation_file = source / "presentation.json"
presentation = json.loads(presentation_file.read_text()) if presentation_file.exists() and archive else None
if presentation:
    if presentation["release"] != version or hashlib.sha256(manifest.read_bytes()).hexdigest() != presentation["sourceArchiveDigest"]:
        raise ValueError("Modified native presentation source")
    if not presentation["approved"] and not os.environ.get("LILO_RELEASE_PREVIEW"):
        raise ValueError("Release presentation awaits visual approval")
approved = archive.get("approval", {}).get("passed") is True if archive.get("schemaVersion") == 3 else archive.get("visualReview", {}).get("passed") is True
if archive.get("schemaVersion") in (2, 3) and archive.get("release") == version and approved:
    scenarios = [highlight["id"] for highlight in archive["plan"]["highlights"]] if archive["schemaVersion"] == 3 else ("tab-share", "address-bar")
    for scenario in scenarios:
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,47}", scenario):
            raise ValueError("Unsafe release media filename")
        entry = presentation["media"][scenario] if presentation else archive["recordings"][scenario]
        assets = (("poster", "posterDigest"),) if entry.get("kind") == "image" else (("poster", "posterDigest"), ("recording", "recordingDigest"))
        for key, digest in assets:
            name = entry[key]
            if not re.fullmatch(r"[a-z][a-z0-9-]{0,80}\.(png|webp|mp4)", name):
                raise ValueError("Unsafe release media filename")
            data = (source / name).read_bytes()
            if hashlib.sha256(data).hexdigest() != entry[digest]:
                raise ValueError(f"Modified release media: {name}")
            wanted.add(name)
            destination = target / name
            if not destination.exists() or destination.read_bytes() != data:
                shutil.copyfile(source / name, destination)
for destination in target.iterdir():
    if destination.is_file() and destination.name not in wanted:
        destination.unlink()
