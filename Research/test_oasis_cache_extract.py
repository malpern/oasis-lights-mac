import json
from pathlib import Path
import plistlib
import tempfile
import unittest

from oasis_cache_extract import extract_cached_node_groups
from oasis_snapshot import SnapshotError


class OasisCacheExtractTests(unittest.TestCase):
    def test_extracts_valid_node_group_cache_from_private_plist(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "preferences.plist")
            expected = json.dumps({"groups": [{"custom_data": {"automations": []}}], "total": 1})
            path.write_bytes(plistlib.dumps({"flutter.node_group_cache": expected}))
            path.chmod(0o600)
            self.assertEqual(extract_cached_node_groups(path), expected.encode())

    def test_rejects_plist_without_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "preferences.plist")
            path.write_bytes(plistlib.dumps({"unrelated": True}))
            path.chmod(0o600)
            with self.assertRaises(SnapshotError):
                extract_cached_node_groups(path)


if __name__ == "__main__":
    unittest.main()
