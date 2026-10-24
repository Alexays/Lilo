"""Prepare the app's release notes and versions through Changie. Invoked by the Makefile."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


def sync_version(version, check):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError(f"Invalid app version: {version}")
    config_path = Path("Xcode/Configs/Base.xcconfig")
    config = config_path.read_text()
    marketing = re.search(r"^MARKETING_VERSION = (\S+)$", config, re.MULTILINE)
    build = re.search(r"^CURRENT_PROJECT_VERSION = (\d+)$", config, re.MULTILINE)
    if not marketing or not build:
        raise ValueError(f"Missing app version or build number in {config_path}")
    if marketing[1] != version:
        config = re.sub(r"^MARKETING_VERSION = \S+$", f"MARKETING_VERSION = {version}", config, flags=re.MULTILINE)
        config = re.sub(r"^CURRENT_PROJECT_VERSION = \d+$", f"CURRENT_PROJECT_VERSION = {int(build[1]) + 1}", config, flags=re.MULTILINE)
    updates = {config_path: config}
    for directory in ["lilo-ui", "Lilo/Extensions/bridge-src"]:
        for name in ["package.json", "package-lock.json"]:
            path = Path(directory) / name
            data = json.loads(path.read_text())
            data["version"] = version
            if name == "package-lock.json":
                data["packages"][""]["version"] = version
            updates[path] = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    for path, content in updates.items():
        if path.read_text() == content:
            continue
        if check:
            raise ValueError(f"{path} is out of sync with Changie; run make release-version")
        path.write_text(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["status", "version"])
    parser.add_argument("--changie", required=True)
    args = parser.parse_args()

    def changie(*arguments):
        return subprocess.check_output([args.changie, *arguments], text=True)

    pending = list(Path(".changes/unreleased").glob("*.yaml"))
    if args.command == "version":
        if pending:
            changie("batch", "auto", "--allow-no-changes=false")
        changie("merge")
        sync_version(changie("latest", "--remove-prefix").strip(), check=False)
    else:
        sync_version(changie("latest", "--remove-prefix").strip(), check=True)
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
