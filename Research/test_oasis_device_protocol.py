import unittest

from oasis_device_protocol import (
    BRIGHTNESS_OPCODE,
    EFFECT_RAINMAKER_COMMAND_ID,
    LIGHT_BLINK_COMMAND_ID,
    LIGHT_SET_COMMAND_ID,
    OASIS_COMPANY_ID,
    POWER_OPCODE,
    TEMPERATURE_OPCODE,
    effect_rainmaker_data,
    decode_missing_data_flags,
    decode_response,
    encode_brightness,
    encode_light_blink,
    encode_light_mode,
    encode_power,
    encode_rgb_triplet,
    encode_provisioning_mode,
    encode_temperature,
    encode_temperature_brightness,
    encode_transition_preview,
    encode_wifi_credentials,
    light_set_rainmaker_data,
    unpack_vendor_message_id,
    vendor_message_id,
)


class OasisDeviceProtocolTests(unittest.TestCase):
    def test_vendor_message_id_matches_native_integer(self):
        self.assertEqual(vendor_message_id(POWER_OPCODE), 0xC3E502)
        self.assertEqual(unpack_vendor_message_id(0xC4E502), (BRIGHTNESS_OPCODE, OASIS_COMPANY_ID))
        self.assertEqual(vendor_message_id(TEMPERATURE_OPCODE), 0xC5E502)
        self.assertEqual(vendor_message_id(LIGHT_SET_COMMAND_ID), 0xC6E502)

    def test_effect_and_light_blink_share_transport_specific_cb_id(self):
        self.assertEqual(EFFECT_RAINMAKER_COMMAND_ID, LIGHT_BLINK_COMMAND_ID)

    def test_power(self):
        self.assertEqual(encode_power(False), b"\x00")
        self.assertEqual(encode_power(True), b"\x01")

    def test_brightness(self):
        self.assertEqual(encode_brightness(80, 0x12345678), bytes.fromhex("50 78 56 34 12"))

    def test_temperature(self):
        self.assertEqual(encode_temperature(2400), bytes.fromhex("60 09"))
        self.assertEqual(encode_temperature(4000), bytes.fromhex("a0 0f"))

    def test_light_set_rainmaker_data(self):
        self.assertEqual(
            light_set_rainmaker_data(0.25, 0, 1, 0.5, 0.75),
            {"red": 0.25, "green": 0.0, "blue": 1.0, "cold": 0.5, "warm": 0.75},
        )

    def test_rgb_triplet_truncates_like_oasis(self):
        self.assertEqual(encode_rgb_triplet(0.0, 0.5, 1.0), bytes.fromhex("00 7f ff"))

    def test_light_blink(self):
        self.assertEqual(
            encode_light_blink(0x11, 0x22, 0x33, 2400, 50, 10_000, 3),
            bytes.fromhex("11 22 33 60 09 32 10 27 00 00 03"),
        )

    def test_transition_preview(self):
        self.assertEqual(
            encode_transition_preview(2400, 50, 60_000),
            bytes.fromhex("60 09 32 60 ea 00 00"),
        )
        self.assertEqual(encode_transition_preview(0, 0, 0), bytes(7))

    def test_light_mode(self):
        self.assertEqual(encode_light_mode("color"), b"\x01")
        self.assertEqual(encode_light_mode("temperature"), b"\x02")

    def test_temperature_brightness(self):
        self.assertEqual(
            encode_temperature_brightness(2400, 50, 0x12345678),
            bytes.fromhex("60 09 32 78 56 34 12"),
        )

    def test_wifi_credentials_use_utf8_byte_lengths(self):
        self.assertEqual(
            encode_wifi_credentials("Café", "pw"),
            bytes((5,)) + "Café".encode() + bytes((2,)) + b"pw",
        )

    def test_provisioning_mode(self):
        self.assertEqual(encode_provisioning_mode(2, 60_000), bytes.fromhex("02 60 ea 00 00"))

    def test_shared_response(self):
        self.assertEqual(decode_response(b"\x00\x07"), {"success": False, "status": 0, "detail": 7})
        self.assertEqual(decode_response(b"\x01"), {"success": True, "status": 1, "detail": None})

    def test_missing_data_flags(self):
        self.assertEqual(
            decode_missing_data_flags(b"\x05"),
            {"needsTimezone": True, "needsLocation": False, "needsSolarCycle": True},
        )

    def test_effect_data_is_flattened(self):
        self.assertEqual(
            effect_rainmaker_data("ocean", {"flow": 0.5, "warmth": 0.4}),
            {"effect": "ocean", "flow": 0.5, "warmth": 0.4},
        )

    def test_validation_rejects_unsafe_values(self):
        with self.assertRaises(ValueError):
            encode_brightness(101, 0)
        with self.assertRaises(ValueError):
            encode_temperature(-1)
        with self.assertRaises(ValueError):
            encode_wifi_credentials("x" * 256, "")
        with self.assertRaises(ValueError):
            effect_rainmaker_data("ocean", {"effect": 1.0})
        with self.assertRaises(ValueError):
            light_set_rainmaker_data(1.1, 0, 0, 0, 0)
        with self.assertRaises(ValueError):
            encode_light_blink(0, 0, 0, 2400, 101, 0, 1)
        with self.assertRaises(ValueError):
            encode_transition_preview(2400, 50, -1)
        with self.assertRaises(ValueError):
            encode_light_mode("effect")


if __name__ == "__main__":
    unittest.main()
