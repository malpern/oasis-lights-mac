"""Extract Oasis's cached node-group JSON from a protected iOS preferences copy.

The command never displays cached data. Both input and output must be private;
the output is created as a new mode-0600 file and is never overwritten.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import sys

from oasis_snapshot import SnapshotError, validate_private_file, write_private_snapshot


CACHE_KEY = "flutter.node_group_cache"


def extract_cached_node_groups(plist_path: Path) -> bytes:
    # The plist itself can contain Mesh credentials.
    plist_path = validate_private_file(plist_path)
    try:
        preferences = plistlib.loads(Path(plist_path).read_bytes())
        raw_cache = preferences[CACHE_KEY]
        decoded = json.loads(raw_cache)
    except (OSError, plistlib.InvalidFileException, KeyError, TypeError, json.JSONDecodeError):
        raise SnapshotError("protected preferences did not contain a valid node-group cache") from None
    if not isinstance(decoded, dict) or not isinstance(decoded.get("groups"), list):
        raise SnapshotError("node-group cache had an unexpected structure")
    return raw_cache.encode("utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plist", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--extract-cached-home", action="store_true")
    arguments = parser.parse_args(argv)
    if not arguments.extract_cached_home:
        parser.error("--extract-cached-home is required; no file was written")
    try:
        payload = extract_cached_node_groups(arguments.plist)
        write_private_snapshot(arguments.output, payload)
    except SnapshotError as error:
        print(f"Cache extraction failed: {error}", file=sys.stderr)
        return 1
    print(f"Saved protected Oasis cache to {arguments.output} (mode 0600; contents not displayed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
