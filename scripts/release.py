"""Prepare the app's release notes and versions through Changie. Invoked by the Makefile."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


def version_updates(version, released):
    """The files whose content changes to carry `version`; `released` means a new release is being cut."""
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError(f"Invalid app version: {version}")
    updates = {}
    config_path = Path("Xcode/Configs/Base.xcconfig")
    config = config_path.read_text()
    marketing = re.search(r"^MARKETING_VERSION = (\S+)$", config, re.MULTILINE)
    build = re.search(r"^CURRENT_PROJECT_VERSION = (\d+)$", config, re.MULTILINE)
    if not marketing or not build:
        raise ValueError(f"Missing app version or build number in {config_path}")
    if released or marketing[1] != version:
        config = re.sub(r"^MARKETING_VERSION = \S+$", f"MARKETING_VERSION = {version}", config, flags=re.MULTILINE)
        config = re.sub(r"^CURRENT_PROJECT_VERSION = \d+$", f"CURRENT_PROJECT_VERSION = {int(build[1]) + 1}", config, flags=re.MULTILINE)
        updates[config_path] = config
    for directory in ["lilo-ui", "Lilo/Extensions/bridge-src"]:
        for name in ["package.json", "package-lock.json"]:
            path = Path(directory) / name
            data = json.loads(path.read_text())
            root = data["packages"][""] if name == "package-lock.json" else data
            # Rewritten only when a version differs, so the file keeps npm's formatting otherwise.
            if data["version"] != version or root["version"] != version:
                data["version"] = root["version"] = version
                updates[path] = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    return updates


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["status", "version"])
    parser.add_argument("--changie", required=True)
    args = parser.parse_args()

    def changie(*arguments):
        return subprocess.check_output([args.changie, *arguments], text=True)

    pending = list(Path(".changes/unreleased").glob("*.yaml"))
    if args.command == "version":
        # Every file is read and checked before the batch consumes the fragments.
        if pending:
            version = changie("next", "auto").strip().removeprefix("v")
            updates = version_updates(version, released=True)
            changie("batch", "auto", "--allow-no-changes=false")
        else:
            updates = version_updates(changie("latest", "--remove-prefix").strip(), released=False)
        changie("merge")
        for path, content in updates.items():
            path.write_text(content)
    else:
        updates = version_updates(changie("latest", "--remove-prefix").strip(), released=False)
        if updates:
            raise ValueError(f"{next(iter(updates))} is out of sync with Changie; run make release-version")
        if Path("CHANGELOG.md").read_text() != changie("merge", "--dry-run"):
            raise ValueError("CHANGELOG.md is out of sync with Changie; run make release-version")
        if pending:
            print(changie("batch", "auto", "--dry-run", "--allow-no-changes=false"), end="")
        else:
            print("No pending release notes.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
