"""Announce a published GitHub release through Discord. Invoked by the Makefile."""
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def publish(event, webhook_url):
    release = event["release"]
    tag = release["tag_name"]
    if (event["action"] != "published" or release["draft"] or release["prerelease"]
            or not re.fullmatch(r"v\d+\.\d+\.\d+", tag)):
        print("Skipping an unpublished, prerelease or non-app release.")
        return
    if not webhook_url:
        raise RuntimeError("Set DISCORD_WEBHOOK_URL in GitHub's release environment.")

    url = release["html_url"]
    notes = (release.get("body") or "").strip()
    # Discord does not render the reference links Changie writes for version headings.
    notes = re.sub(r"(?m)^## \[([^\]]+)\](?!\()", r"## \1", notes)
    notes = re.sub(r"(?m)^\[[^\]]+\]:\s*(https://\S+)[ \t]*$", r"[Compare changes](\1)", notes)
    if len(notes) > 4096:
        suffix = f"\n\n[Read the full changelog]({url})"
        notes = notes[:4096 - len(suffix)].rsplit("\n", 1)[0].rstrip() + suffix
    payload = {
        "allowed_mentions": {"parse": []},
        "embeds": [{
            "title": f"Lilo {tag}",
            "url": url,
            "description": notes or f"[Read the changelog]({url})",
        }],
    }
    try:
        separator = "&" if "?" in webhook_url else "?"
        request = Request(
            f"{webhook_url}{separator}wait=true", json.dumps(payload).encode(),
            {"Content-Type": "application/json", "User-Agent": "Lilo release announcements"},
            method="POST",
        )
        with urlopen(request, timeout=30) as response:
            response.read()
    except HTTPError as error:
        error.close()
        raise RuntimeError(f"Discord rejected the announcement (HTTP {error.code}).") from None
    except (OSError, ValueError):
        # Network exceptions can contain the webhook token; keep it out of the job log.
        raise RuntimeError("Could not send the Discord announcement; check the webhook and network.") from None
    print(f"Announced Lilo {tag} on Discord.")


if __name__ == "__main__":
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        publish(event, os.environ.get("DISCORD_WEBHOOK_URL", ""))
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        sys.exit(str(error))
