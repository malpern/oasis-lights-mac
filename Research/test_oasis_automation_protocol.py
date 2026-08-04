import unittest

from oasis_automation_protocol import (
    automations_for_room,
    decode_days,
    encode_location_ble,
    encode_timezone_ble,
    encode_days,
    find_home_group,
    location_command,
    location_analytics_event,
    merge_automation,
    node_command,
    room_automation_commands,
    timezone_command,
    timezone_analytics_event,
)


def automation(**changes):
    value = {
        "id": "automation-1",
        "name": "Morning",
        "enabled": True,
        "brightness": 60,
        "temperature": 3000,
        "fadeDuration": 900,
        "daysOfWeek": 127,
        "startTime": {"type": "sunrise", "offset": -30},
        "roomIDs": ["room-1"],
        "futureAutomationField": "keep-me",
    }
    value.update(changes)
    return value


class OasisAutomationProtocolTests(unittest.TestCase):
    def test_weekday_mask_is_sunday_first(self):
        self.assertEqual(encode_days(["sunday", "saturday"]), 65)
        self.assertEqual(decode_days(65), ("sunday", "saturday"))

    def test_merge_preserves_unknown_fields(self):
        home = {
            "home_group": True,
            "automations": [automation()],
            "futureHomeField": {"keep": True},
        }
        merged = merge_automation(home, automation(brightness=35))
        self.assertEqual(merged["automations"][0]["brightness"], 35)
        self.assertEqual(merged["automations"][0]["futureAutomationField"], "keep-me")
        self.assertEqual(merged["futureHomeField"], {"keep": True})

    def test_room_filter_includes_disabled_automations(self):
        selected = automations_for_room(
            [automation(enabled=False), automation(id="automation-2", roomIDs=["room-2"])],
            "room-1",
        )
        self.assertEqual([item["id"] for item in selected], ["automation-1"])

    def test_node_command_matches_decoded_envelope(self):
        body = node_command(["node-1", "node-2"], [automation()])
        self.assertEqual(body["cmd"], 2051)
        self.assertEqual(body["timeout"], 2_592_000)
        self.assertTrue(body["override"])
        self.assertEqual(body["data"]["automations"][0]["id"], "automation-1")

    def test_location_encoding_and_remote_shapes(self):
        # Static decode uses truncation toward zero after multiplying by 1e6.
        self.assertEqual(
            encode_location_ble(37.774929, -122.419416),
            bytes.fromhex("02406651 f8b40728"),
        )
        body = location_command(["node-1"], 37.774929, -122.419416)
        self.assertEqual(body["cmd"], 2049)
        self.assertEqual(body["data"], {"lat": 37.774929, "lng": -122.419416})
        self.assertEqual(
            location_analytics_event(37.774929, -122.419416),
            ("Location Set", {"latitude": 37.774929, "longitude": -122.419416}),
        )

    def test_timezone_encoding_and_remote_shapes(self):
        self.assertEqual(encode_timezone_ble("America/Los_Angeles"), b"America/Los_Angeles")
        body = timezone_command(["node-1"], "America/Los_Angeles")
        self.assertEqual(body["cmd"], 2050)
        self.assertEqual(body["data"], {"timezone": "America/Los_Angeles"})
        self.assertEqual(
            timezone_analytics_event("America/Los_Angeles"),
            ("Timezone Set", {"timezone": "America/Los_Angeles"}),
        )

    def test_cached_home_group_builds_room_commands_by_group_id(self):
        snapshot = {
            "groups": [
                {
                    "group_id": "home-group",
                    "nodes": ["node-1", "node-2"],
                    "sub_groups": [
                        {
                            "group_id": "rainmaker-room-group",
                            "nodes": ["node-1", "node-2"],
                            "custom_data": {"room_id": "different-app-room-id"},
                        }
                    ],
                    "custom_data": {
                        "home_group": True,
                        "automations": [automation(roomIDs=["rainmaker-room-group"])],
                        "ble_mesh_config": {"future": "preserve"},
                    },
                }
            ]
        }
        self.assertEqual(find_home_group(snapshot)["group_id"], "home-group")
        commands = room_automation_commands(snapshot)
        self.assertEqual(list(commands), ["rainmaker-room-group"])
        self.assertEqual(commands["rainmaker-room-group"]["node_ids"], ["node-1", "node-2"])
        self.assertEqual(
            commands["rainmaker-room-group"]["data"]["automations"][0]["id"],
            "automation-1",
        )


if __name__ == "__main__":
    unittest.main()
