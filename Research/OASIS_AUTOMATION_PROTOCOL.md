# Oasis automation protocol (Android 2.7.0)

This document records a static decode of the official Oasis Android 2.7.0
release, checked against a protected cache and read-only UI inspection in Oasis
iOS 2.7.1. No pairing operation or saved automation change was made.

The broader transport, command, device-family, Matter, color, and effect map is
in `OASIS_DEVICE_SOFTWARE_MAP.md`.

## Compatibility model

Oasis uses two related representations:

1. The full Home Group lives in RainMaker node-group `custom_data`. Oasis reads
   and writes that object through `user/node_group`.
2. After a successful Home Group write, Oasis filters the home-wide automation
   list by room and sends each room its own complete list with RainMaker command
   `2051` through `user/nodes/cmd`.

An interoperable client therefore must read the latest Home Group, merge its
change into the existing automation collection, PUT the updated `custom_data`,
and only then dispatch the room-specific device command. It must not maintain a
second, parallel schedule or replace fields it does not understand.

The official app performs the local state update optimistically and rolls it
back if the Home Group synchronization fails. Device dispatch occurs only after
that synchronization succeeds.

## Home Group custom data

The app serializes the following known keys:

```json
{
  "home_group": true,
  "home_group_id": "...",
  "owner_user_id": "...",
  "owner_user_name": "...",
  "version": 0,
  "automations": [],
  "automations_enabled": true,
  "performed_migrations": []
}
```

A real cached Home Group also contains `ble_mesh_config`. That object includes
Mesh credentials and is intentionally not reproduced here. An interoperable
writer must preserve it byte-for-byte as an unknown field and must protect any
raw node-group snapshot as credential-bearing data.

`automations_enabled` is the home-wide automation switch.
`performed_migrations` includes `light_cycle_migration` after the legacy light
cycle has been converted.

Read path:

- `GET https://0sb7eb48mj.execute-api.us-east-1.amazonaws.com/dev/user/node_group`
- query values are `node_list=true`, `sub_groups=true`, and optional `group_id`
- authorization is sent as `Authorization: Bearer <token>`
- the response is decoded as a list of node-group objects
- decoded node-group keys include `sub_groups`, `group_id`, `group_name`,
  `parent_group_id`, `custom_data`, `room_id`, `nodes`,
  `active_scene_ids`, and `home_group`
- the Home Group is parsed from the matching node-group's `custom_data`

The cached response envelope observed from the iOS app is
`{"groups": [...], "total": ...}`. Its Home Group contains one room in
`sub_groups`; both the Home Group and room contain the two RainMaker node IDs.
Automation `roomIDs` matches the room node group's `group_id`, not the separate
`custom_data.room_id` field.

Write path:

- `PUT user/node_group`
- identifies the target with `group_id`
- sends the serialized Home Group as `custom_data`

## Automation object

```json
{
  "id": "...",
  "name": "...",
  "enabled": true,
  "brightness": 50,
  "temperature": 3000,
  "fadeDuration": 900,
  "daysOfWeek": 127,
  "startTime": {"type": "fixed", "minutes": 420},
  "roomIDs": ["..."]
}
```

Start-time variants are:

```json
{"type": "fixed", "minutes": 420}
{"type": "sunrise", "offset": -30}
{"type": "sunset", "offset": 15}
```

`daysOfWeek` is a bitmask over Sunday through Saturday, with Sunday as bit 0.
The app supports at most 20 automations per room.

Known Oasis white-temperature presets are 4000 K (Bright), 3500 K (Neutral),
3000 K (Soft), 2800 K (Glow), 2400 K (Amber), and 2000 K (Candle). The current
local bridge's 2700 K lower clamp is therefore not Oasis-compatible and should
be changed only after a safe physical validation.

## Per-room device command

For each room, the app includes every enabled or disabled automation whose
`roomIDs` contains that room's ID. It sends the entire resulting list, rather
than a single diff:

```json
{
  "cmd": 2051,
  "node_ids": ["rainmaker-node-id"],
  "timeout": 2592000,
  "override": true,
  "data": {
    "automations": [
      {"id": "...", "name": "..."}
    ]
  }
}
```

The timeout is 2,592,000 seconds (30 days). The endpoint is
`user/nodes/cmd`.

The app also uses `user/nodes/params` for ordinary device-parameter writes.
Devices report a
missing-data bitmask in vendor status opcode `13755650`: bit 0 means timezone,
bit 1 location, and bit 2 solar cycle. This is consistent with the complete
schedule being stored and executed on the device rather than fired by phone
timers.

## Location and timezone setup

Sunrise and sunset automations depend on two device-resident values. Oasis
sends each as a vendor command and records an analytics event after success.

Location uses remote command `2049`:

```json
{
  "cmd": 2049,
  "data": {"lat": 37.0, "lng": -122.0}
}
```

The BLE message uses Oasis company ID `0x02E5`, opcode `0xCF`, and an eight-byte
payload. Latitude and longitude are each multiplied by 1,000,000, truncated
toward zero, encoded as signed 32-bit integers, and written in big-endian
order. After the command, the app records analytics event `Location Set` with
`{"latitude": ..., "longitude": ...}`.

Timezone uses remote command `2050`:

```json
{
  "cmd": 2050,
  "data": {"timezone": "America/Los_Angeles"}
}
```

The BLE message uses company ID `0x02E5`, opcode `0xC9`, with the timezone name
as its byte payload. After the command, the app records analytics event
`Timezone Set` with the same `timezone` value. The official pairing flow sends
timezone first and location second.

## Legacy LightCycle migration

The legacy object is:

```json
{
  "version": 0,
  "isDynamicSunset": true,
  "phases": [
    {"brightness": 50, "temperature": 3000, "time": {
      "hours": 7, "minutes": 0, "totalMinutes": 420
    }}
  ]
}
```

Legacy phase names include `morning`, `evening`, and `night`. Oasis 2.7.0
converts these phases to ordinary Home Group automations and records
`light_cycle_migration`.

## Offline cached account evidence

A protected iOS preferences copy made during the earlier attached-phone work
contained a valid `flutter.node_group_cache`, so the current analysis no longer
depends entirely on the Android schema. The cache was extracted to a separate
mode-0600 temporary JSON file without displaying identifiers or Mesh keys.

The August 2 cache contains:

- one Home Group, one room, and two nodes
- Home Group version 1 with automations globally enabled
- three enabled, every-day automations assigned to that room:
  - 10:00, 80%, 3500 K, five-minute fade
  - 30 minutes before sunset, 50%, 2400 K, 30-minute fade
  - 23:59, 0%, 2400 K, five-minute fade
- legacy Cycle version 1 with dynamic sunset enabled and the corresponding
  morning, evening, and night phase values
- `is_matter=false` on both the Home Group and room records

This is strong evidence that the daily behavior is the migrated LightCycle,
stored as three regular Oasis automations and executed by the existing BLE Mesh
devices. It also provides a real, round-trip fixture: a no-op automation merge
preserved the full `custom_data` exactly, and the decoded room dispatch produced
one command-2051 envelope containing all three automations for both node IDs.
Because it is a cache rather than a fresh API response, it still needs a live
read before any future write.

Room records also preserve `active_scene_ids`, but Android 2.7.0 only parses and
serializes that list; it contains no lighting-scene activation sender or scene
UI. A compatible no-op merge must retain the field unchanged. It is not part of
the Light Cycle schedule and there is not yet enough protocol evidence to
create or activate Oasis scenes independently.

The app also has a separate local `C7` transition-preview command containing
temperature, brightness, and duration milliseconds. Its Light Cycle editor
uses a 60-second preview, and session teardown sends an all-zero payload. This
command is transient UI feedback; it is not how the schedule is stored or
distributed and should not be used as a replacement automation mechanism.

Read-only inspection of the live iOS Light Cycle UI confirmed all three entries
remain active and repeat every day. Their editors showed Neutral at 80% for
10:00, Amber at 50% for the sunset-relative entry, and lights off at 23:59.
The sunset editor displays the currently resolved local clock time, while the
cached automation preserves the actual solar-relative rule. Each editor was
closed without saving.

## Static evidence

The principal ARM64 snapshot offsets in `libapp.so` are:

- `0x4e63c4`: Home Group serialization
- `0x309bb8`: automation-list parsing from `automations`
- `0x306650`: automation serialization
- `0x835c78`: command data serialization to `{automations: [...]}`
- `0x838408`: tagged Dart integer for command 2051 (`0x1006 >> 1`)
- `0x305e5c`: node-command envelope construction
- `0x89221c`: command getter dispatch and send
- `0x892300`: `user/nodes/cmd` request
- `0x88da54`: `user/node_group` read
- `0x30bd84`: node-group JSON parsing
- `0x897114`: `user/node_group` update construction
- `0x8eb45c`: Home Group synchronization
- `0x8eb170`: per-room filtering and dispatch
- `0x3065f0`: `roomIDs.contains(room.id)` filter
- `0x832464`: BLE location payload encoding
- `0x835c3c`: BLE location message ID (`0xCF`, company `0x02E5`)
- `0x8369d0`: remote location data serialization to `{lat, lng}`
- `0x838470`: tagged remote location command 2049 (`0x1003 >> 1`)
- `0x832a20`: BLE timezone payload encoding
- `0x835c6c`: BLE timezone message ID (`0xC9`, company `0x02E5`)
- `0x836e0c`: remote timezone data serialization
- `0x8384e0`: tagged remote timezone command 2050 (`0x1004 >> 1`)
- `0x89404c`: `Location Set` analytics event construction
- `0x8943cc`: `Timezone Set` analytics event construction

The analyzed APK's SHA-256 is
`f77ab5f0c13d8348b76910060d4fbf5d09f58b53fc23732402c71e8b5a4558a3`.

## Remaining live verification

The protected cache supplied the Home Group/room relationship, both associated
node IDs, the current three-automation collection, and legacy-migration state.
It did not establish a currently authorized RainMaker session. Before any
future write, the remaining live work is therefore narrower:

- perform a fresh read-only Home Group fetch and compare its version/content to
  the protected cache
- confirm that the iOS 2.7.1 session and API path accept a read without placing
  the token in logs or chat
- create a second protected snapshot immediately before a merge/write, then
  verify the post-write Home Group and per-room command results

Tokens must remain in a mode-0600 temporary file and must never be printed in a
terminal transcript or chat. No PUT or device command should be sent until a
GET has been saved, redacted, and round-trip checked.

`oasis_snapshot.py` implements only that GET. It refuses non-owner-only token
files, requires `--execute-read-only`, caps the response at 16 MiB, validates
JSON, creates a new mode-0600 output, and never prints response contents. Its
network path has not been executed yet.

`oasis_cache_extract.py` extracts `flutter.node_group_cache` from a protected
iOS preferences copy into a new mode-0600 JSON file. It never prints the cached
data and refuses to overwrite an existing output.
