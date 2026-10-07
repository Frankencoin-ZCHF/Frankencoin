#!/usr/bin/env python3
"""Fetch locked source snapshots, extracting only source/license paths (no Git histories).
Existing files are never silently overwritten: mismatches fail. No shell commands executed.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    lock = json.loads((root / "dependencies.lock.json").read_text())
    report = []
    for dep in lock["dependencies"]:
        url = f"https://codeload.github.com/{dep['repository']}/tar.gz/{dep['commit']}"
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
        archive_hash = hashlib.sha256(data).hexdigest()
        count = 0
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            for member in archive.getmembers():
                parts = PurePosixPath(member.name).parts[1:]
                if not parts or not member.isfile():
                    continue
                if ".." in parts or PurePosixPath(*parts).is_absolute():
                    raise ValueError("unsafe archive member")
                name = "/".join(parts)
                if not any(name.startswith(prefix) for prefix in dep["include"]):
                    continue
                destination = root / dep["path"] / name
                stream = archive.extractfile(member)
                if stream is None:
                    raise ValueError("regular file has no content")
                content = stream.read()
                if destination.exists() and destination.read_bytes() != content:
                    raise ValueError(f"existing dependency differs from pin: {destination}")
                if not destination.exists():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(content)
                count += 1
        print(f"{dep['name']}: {dep['commit']} verified/extracted {count} files")
        report.append({"name": dep["name"], "commit": dep["commit"], "url": url,
                       "archiveSha256": archive_hash, "files": count})
    target = root / "evidence" / "dependency-downloads.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, indent=2) + "\n")

if __name__ == "__main__":
    main()
