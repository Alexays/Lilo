"""Fetch one CC0 track from its creator's free music bundle."""

import hashlib
import io
import json
from http.cookiejar import CookieJar
from pathlib import Path
import re
from urllib.parse import urlencode
from urllib.request import HTTPCookieProcessor, Request, build_opener
import zipfile


ROOT = Path(__file__).parent
PAGE = "https://tallbeard.itch.io/music-loop-bundle"
TRACK = "Week 37 - Schmoovin.ogg"
EXPECTED_SHA256 = "076d06a68ce9dc8f7d2401afa05e247ad3849ac4d425c3b28f995c15bfdab007"


def fetch():
    target = ROOT / "music.ogg"
    if target.exists() and (ROOT / "music.LICENSE.txt").exists():
        if hashlib.sha256(target.read_bytes()).hexdigest() == EXPECTED_SHA256:
            print("Verified bundled CC0 music")
            return
    opener = build_opener(HTTPCookieProcessor(CookieJar()))
    with opener.open(f"{PAGE}/purchase", timeout=15) as response:
        html = response.read().decode()
    csrf = re.search(r'name="csrf_token" value="([^"]+)"', html)[1]
    request = Request(
        f"{PAGE}/file/19538393?source=game_download",
        data=urlencode({"csrf_token": csrf}).encode(),
        headers={"Referer": f"{PAGE}/purchase", "X-Requested-With": "XMLHttpRequest"},
    )
    with opener.open(request, timeout=15) as response:
        download = json.load(response)["url"]
    with opener.open(download, timeout=15) as response:
        archive = zipfile.ZipFile(io.BytesIO(response.read()))
    music = archive.read(TRACK)
    digest = hashlib.sha256(music).hexdigest()
    if digest != EXPECTED_SHA256:
        raise ValueError("The CC0 music source changed; verify its license before updating the pin")
    target.write_bytes(music)
    (ROOT / "music.LICENSE.txt").write_bytes(archive.read("_LICENSE.txt"))
    print(f"Downloaded {TRACK}: {digest}")


if __name__ == "__main__":
    fetch()
