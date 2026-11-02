#!/usr/bin/env python3
"""Print the newest macOS release whose WebKit security fixes are all in a WebKit checkout.

Usage: scripts/webkit-fork-coverage.py <WebKit checkout> <macOS major version>

Apple's security advisories list the WebKit bugs each release fixes ("WebKit Bugzilla: N"), and each
WebKit commit names its bug URL. A release of that macOS is covered when every bug of its advisory, and of
every earlier one, has a commit in the checkout's history (fetch it with --filter=blob:none, not --depth); a
release without published CVEs is covered with the one before. The fork runs only up to that release:
see docs/WEBKIT_FORK.md.
"""
import html
import re
import subprocess
import sys
import urllib.request

RELEASES = "https://support.apple.com/en-us/100100"


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8", "replace")


def main(checkout, major):
    # (version, is a Background Security Improvement, advisory URL or None when it has no CVE)
    releases = []
    for row in re.findall(r"<tr.*?</tr>", fetch(RELEASES), re.S):
        text = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", row))).strip()
        link = re.search(r'href="(https://support\.apple\.com/[a-z-]+/\d+)"', row)
        url = None if "no published CVE entries" in text else link and link.group(1)
        if match := re.match(rf"macOS [A-Za-z ]+? ({major}(?:\.\d+)*) ", text + " "):
            releases.append((match.group(1), False, url))
        elif text.startswith("Background Security Improvements") and (match := re.search(rf"macOS ({major}(?:\.\d+)*)", text)):
            releases.append((match.group(1), True, url))
    if not releases:
        sys.exit(f"No macOS {major} release on {RELEASES}")

    log = subprocess.run(["git", "-C", checkout, "log", "--format=%B", "HEAD"], check=True, capture_output=True, text=True).stdout
    fixed = set(re.findall(r"show_bug\.cgi\?id=(\d+)", log))

    covered = None
    for version, improvement, url in sorted(releases, key=lambda release: (tuple(map(int, release[0].split("."))), release[1])):
        missing = sorted(set(re.findall(r"WebKit Bugzilla: (\d+)", fetch(url))) - fixed) if url else []
        if missing:
            print(f"macOS {version}{' (a)' if improvement else ''}: {len(missing)} WebKit fixes not in the checkout ({', '.join(missing)})", file=sys.stderr)
            break
        if not improvement:
            covered = version
    if covered is None:
        sys.exit(f"macOS {major} itself has WebKit fixes the checkout misses: is its history complete?")
    print(covered)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
