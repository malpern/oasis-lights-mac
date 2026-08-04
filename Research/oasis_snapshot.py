"""Protected, read-only Oasis Home Group snapshot client.

The endpoint and request shape were recovered statically from Oasis Android
2.7.0. Importing this module performs no network I/O. The CLI deliberately
requires an explicit execution flag and never prints response data or tokens.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat
import sys
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


API_ROOT = "https://0sb7eb48mj.execute-api.us-east-1.amazonaws.com/dev"
MAX_RESPONSE_BYTES = 16 * 1024 * 1024


class SnapshotError(RuntimeError):
    """A safe-to-display snapshot failure that contains no credentials."""


def validate_private_file(path: Path) -> Path:
    """Require a regular, current-user-owned file with no group/other access."""
    path = Path(path)
    try:
        metadata = path.lstat()
    except OSError:
        raise SnapshotError("token file could not be opened") from None
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise SnapshotError("token path must be a regular file, not a symlink")
    if metadata.st_uid != os.getuid():
        raise SnapshotError("token file must be owned by the current user")
    if metadata.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        raise SnapshotError("input file permissions must be owner-only (mode 0600)")
    return path


def read_private_token(path: Path) -> str:
    """Read a token from a regular, owner-only file without exposing it."""
    path = validate_private_file(path)
    try:
        token = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError):
        raise SnapshotError("token file could not be read as text") from None
    if not token or any(character.isspace() for character in token):
        raise SnapshotError("token file must contain one non-empty token")
    if token.casefold().startswith("bearer"):
        raise SnapshotError("token file must contain the raw token without a Bearer prefix")
    return token


def snapshot_url(group_id: str | None = None) -> str:
    query: dict[str, str] = {"node_list": "true", "sub_groups": "true"}
    if group_id:
        query["group_id"] = group_id
    return f"{API_ROOT}/user/node_group?{urlencode(query)}"


def fetch_snapshot(
    token: str,
    group_id: str | None = None,
    *,
    opener: Callable[..., Any] = urlopen,
) -> bytes:
    """Perform the decoded GET and return a JSON response without logging it."""
    request = Request(
        snapshot_url(group_id),
        method="GET",
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )
    try:
        with opener(request, timeout=30) as response:
            payload = response.read(MAX_RESPONSE_BYTES + 1)
    except HTTPError as error:
        raise SnapshotError(f"Oasis returned HTTP {error.code}") from None
    except URLError:
        raise SnapshotError("could not reach the Oasis service") from None
    if len(payload) > MAX_RESPONSE_BYTES:
        raise SnapshotError("Oasis response exceeded the 16 MiB safety limit")
    try:
        json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise SnapshotError("Oasis response was not valid JSON") from None
    return payload


def write_private_snapshot(path: Path, payload: bytes) -> None:
    """Create a new mode-0600 snapshot file; never overwrite an existing file."""
    path = Path(path)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
    except FileExistsError:
        raise SnapshotError("snapshot output already exists; choose a new path") from None
    except OSError:
        raise SnapshotError("snapshot output could not be created") from None
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
    except Exception:
        path.unlink(missing_ok=True)
        raise


def capture_snapshot(token_path: Path, output_path: Path, group_id: str | None = None) -> None:
    if Path(token_path).resolve() == Path(output_path).resolve():
        raise SnapshotError("token and snapshot paths must be different")
    token = read_private_token(token_path)
    payload = fetch_snapshot(token, group_id)
    write_private_snapshot(output_path, payload)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--token-file", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--group-id")
    parser.add_argument(
        "--execute-read-only",
        action="store_true",
        help="explicitly permit the single Oasis GET request",
    )
    arguments = parser.parse_args(argv)
    if not arguments.execute_read_only:
        parser.error("--execute-read-only is required; no request was made")
    try:
        capture_snapshot(arguments.token_file, arguments.output, arguments.group_id)
    except SnapshotError as error:
        print(f"Snapshot failed: {error}", file=sys.stderr)
        return 1
    print(f"Saved protected Oasis snapshot to {arguments.output} (mode 0600; contents not displayed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
