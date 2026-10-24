#!/usr/bin/env python3
"""Keep the JSON-LD of the HTML pages in step: the FAQPage with the visible FAQ, softwareVersion with the app."""
import html
import json
import re
from pathlib import Path

PUBLIC = Path(__file__).resolve().parent / "public"
XCCONFIG = PUBLIC.parent.parent / "Xcode/Configs/Base.xcconfig"
PAGES = ["index.html", "moving/index.html", "fr/index.html", "fr/moving/index.html"]


def plain(fragment):
    return html.unescape(re.sub(r"<[^>]+>", "", fragment)).strip()


def sync_json_ld(path, version):
    """Keeps the FAQPage equal to the visible FAQ and softwareVersion equal to the app's MARKETING_VERSION."""
    file = PUBLIC / path
    src = file.read_text()
    faq = [
        {"@type": "Question", "name": plain(q), "acceptedAnswer": {"@type": "Answer", "text": plain(a)}}
        for q, a in re.findall(r"<details><summary>(.*?)</summary><p>(.*?)</p></details>", src)
    ]
    match = re.search(r'<script type="application/ld\+json">(.*?)</script>', src, re.S)
    data = json.loads(match.group(1))
    for node in data["@graph"]:
        if node["@type"] == "FAQPage":
            node["mainEntity"] = faq
        if node["@type"] == "SoftwareApplication":
            node["softwareVersion"] = version
    ld = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    assert "</" not in ld
    file.write_text(src[: match.start(1)] + ld + src[match.end(1) :])


version = re.search(r"^MARKETING_VERSION = (\S+)", XCCONFIG.read_text(), re.M).group(1)
for path in PAGES:
    sync_json_ld(path, version)
