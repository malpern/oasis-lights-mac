import json
import os
from pathlib import Path
import stat
import tempfile
import unittest

from oasis_snapshot import (
    SnapshotError,
    fetch_snapshot,
    read_private_token,
    snapshot_url,
    write_private_snapshot,
)


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, _limit):
        return self.payload


class OasisSnapshotTests(unittest.TestCase):
    def test_url_contains_read_only_group_query(self):
        self.assertEqual(
            snapshot_url("home id"),
            "https://0sb7eb48mj.execute-api.us-east-1.amazonaws.com/dev/"
            "user/node_group?node_list=true&sub_groups=true&group_id=home+id",
        )

    def test_fetch_uses_bearer_header_and_preserves_response(self):
        expected = json.dumps({"node_groups": []}).encode()
        observed = {}

        def opener(request, timeout):
            observed["url"] = request.full_url
            observed["authorization"] = request.get_header("Authorization")
            observed["timeout"] = timeout
            return FakeResponse(expected)

        self.assertEqual(fetch_snapshot("test-token", opener=opener), expected)
        self.assertEqual(observed["authorization"], "Bearer test-token")
        self.assertEqual(observed["timeout"], 30)
        self.assertIn("node_list=true", observed["url"])

    def test_token_file_must_be_owner_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "token")
            path.write_text("secret\n")
            path.chmod(0o644)
            with self.assertRaises(SnapshotError):
                read_private_token(path)
            path.chmod(0o600)
            self.assertEqual(read_private_token(path), "secret")

    def test_snapshot_is_0600_and_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "snapshot.json")
            write_private_snapshot(path, b"{}")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with self.assertRaises(SnapshotError):
                write_private_snapshot(path, b'{"changed":true}')
            self.assertEqual(path.read_bytes(), b"{}")


if __name__ == "__main__":
    unittest.main()
