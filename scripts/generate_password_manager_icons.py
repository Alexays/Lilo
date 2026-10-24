#!/usr/bin/env python3
"""Regenerate the onboarding's password manager icons from each extension's own store package (needs Pillow)."""
import io, json, os, re, struct, sys, urllib.request, zipfile
from PIL import Image

# The onboarding draws them at 30 pt; 2x for Retina.
SIZE = 60
STORE_URL = "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=141.0&acceptformat=crx3&x=id%3D{id}%26uc"

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
model_path = os.path.join(root, "lilo-ui", "src", "components", "onboarding", "onboardingModel.ts")
output_dir = os.path.join(root, "lilo-ui", "public", "password-managers")

with open(model_path, encoding="utf-8") as f:
    managers = re.search(r"PASSWORD_MANAGERS[^=]*=\s*\[(.*?)\];", f.read(), re.S).group(1)
ids = re.findall(r'\bid: "([a-p]{32})"', managers)
if not ids:
    sys.exit(f"error: no store ids found in {model_path}")

os.makedirs(output_dir, exist_ok=True)
for name in os.listdir(output_dir):
    if name.removesuffix(".png") not in ids:
        os.remove(os.path.join(output_dir, name))

total = 0
for extension_id in ids:
    with urllib.request.urlopen(STORE_URL.format(id=extension_id)) as response:
        crx = response.read()
    if crx[:4] != b"Cr24" or struct.unpack("<I", crx[4:8])[0] != 3:
        sys.exit(f"error: {extension_id}: not a CRX3 package")
    package = zipfile.ZipFile(io.BytesIO(crx[12 + struct.unpack("<I", crx[8:12])[0]:]))
    icons = json.loads(package.read("manifest.json").decode("utf-8-sig")).get("icons", {})
    if not icons:
        sys.exit(f"error: {extension_id}: the manifest declares no icons")
    # The largest icon downscales the sharpest.
    size = max(icons, key=int)
    icon = Image.open(io.BytesIO(package.read(icons[size].lstrip("/")))).convert("RGBA")
    icon = icon.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    output = os.path.join(output_dir, f"{extension_id}.png")
    # At this size a 256-color palette looks the same as full color, at a fraction of the bytes.
    icon.quantize(256, Image.Quantize.FASTOCTREE).save(output, optimize=True)
    total += os.path.getsize(output)
    print(f"{extension_id}: {size} px source, {os.path.getsize(output):,} bytes")
print(f"{len(ids)} icons, {total:,} bytes in {os.path.relpath(output_dir, root)}")
