# Oasis device and software map

This is an interoperability-oriented decode of Oasis Android 2.7.0, correlated
with a protected iOS cache and redacted live diagnostics from Oasis iOS 2.7.1.
The live checks made only reversible light-control changes and restored the
observed values; no pairing, provisioning, room, or saved automation state was
changed. Credential values, node IDs, Matter codes, and Mesh keys are
intentionally omitted.

## High-level architecture

The app is not a thin Matter controller. It is a Flutter application with a
native Android bridge and three distinct Oasis/RainMaker control paths:

```text
Flutter UI and account model
  |-- BLE Mesh proxy --> Oasis vendor model 0x02E5C00A
  |-- LAN local ctrl --> mDNS + encrypted Espressif protobuf messages
  `-- RainMaker cloud -> node params, commands, groups, Matter data

Home Group custom_data
  |-- room membership and RainMaker node IDs
  |-- automations and legacy LightCycle
  `-- credential-bearing ble_mesh_config
```

The official app chooses between local and remote delivery according to
connectivity and which devices in the target room are reachable. This explains
why a compatible client should preserve the RainMaker/Home Group model even
when normal light control is sent locally.

Live iOS 2.7.1 diagnostics refine this further: a white-temperature or
brightness change is sent immediately over BLE Mesh, then an `ensure` timer
dispatches the same logical command through RainMaker about two seconds later
to both room nodes. Oasis therefore uses cloud reconciliation even when every
online room device is locally reachable over BLE.

For room commands, the decoded policy is explicit: if the Mesh proxy is not
connected, or no matching local devices are found, the app sends remotely. It
also compares BLE-device and RainMaker-node membership and falls back to remote
when a room is out of sync. A caller can force remote delivery. The app records
the selected transport in its command analytics.

## Product and app inventory

- Android package: `com.mixtiles.oasis`, version 2.7.0, build 340.
- The observed installed lights identify as model `ambient2`, firmware
  `2.22.26`; their advertised names begin with `Oasis-AM2`.
- Known product types in the client are Ambient, Ambient 2, A60 bulb, C37
  candle, GU10 spotlight, four- and six-inch downlights, and remote.
- The app exposes capability flags for BLE Mesh, Oasis Remote, Apple Home,
  effects, and Matter.
- Android permissions cover Bluetooth scan/connect/advertise, network and
  Wi-Fi state, location, notifications, wake lock/boot, and optional microphone.
- Major client services include Firebase, Amplitude, Braze, Intercom, Sentry,
  Rive, barcode scanning, secure storage, SQLite, web auth, and video playback.
- The Android build has no native Android Matter-controller stack. Its Matter
  screen is a Flutter/RainMaker flow that requests commissioning data from the
  cloud.

The analyzed Android APK SHA-256 is
`f77ab5f0c13d8348b76910060d4fbf5d09f58b53fc23732402c71e8b5a4558a3`.
The iPhone app under test is 2.7.1 build 2, so Android-only conclusions should
be treated as one nearby implementation, not proof that every iOS detail is
identical.

## BLE Mesh transport

Oasis uses standard Bluetooth Mesh provisioning and proxy services:

- provisioning service `0x1827`, characteristics `0x2ADB` and `0x2ADC`
- proxy service `0x1828`, characteristics `0x2ADD` and `0x2ADE`
- vendor company ID `0x02E5`
- vendor model ID `0x02E5C00A`

The app imports and exports the Mesh network, installs a local provisioner,
uses the first application key, subscribes each light's vendor model to room
groups, and can address a device element, room group, or all-nodes address.
The local provisioner UUID is stored in Android preferences. The Home Group's
`ble_mesh_config` contains Mesh credentials and must always be protected.

The Flutter/native boundary represents the three-byte vendor access header as
one integer in byte order `opcode, company-low, company-high`. Power is thus
`0xC3E502`, not merely `0xC3`. BLE Mesh advertisement service data contains a
NUL-terminated UTF-8 serial number.

### Confirmed vendor commands

| Opcode | Meaning | Payload | Confidence |
|---|---|---|---|
| `C1` | Send Wi-Fi credentials | SSID byte length + UTF-8 SSID + password byte length + UTF-8 password | Static native code |
| `C3` | Power | one byte, `0` or `1` | Static code and live control |
| `C4` | Brightness | percent byte + little-endian uint32 Unix time | Static code and live control |
| `C5` | White temperature | little-endian uint16 kelvin | Redacted live iOS 2.7.1 Access-PDU diagnostics |
| `C6` | Light Set / RGB | RainMaker uses normalized `red`, `green`, `blue`, `cold`, and `warm`; local Mesh sends three RGB bytes, each normalized channel multiplied by 255 and truncated | Static Android code and protected live iOS diagnostics |
| `C7` | Temporary temperature/brightness preview | little-endian uint16 kelvin + percent byte + little-endian uint32 duration milliseconds | Fully decoded static code and call sites |
| `C9` | Timezone | UTF-8 IANA timezone | Static code |
| `CA` | Factory reset devices | one byte, `AA`; remote command 2048 | Fully decoded static code and factory-reset UI path; destructive, never send during exploration |
| `CB` | Light Blink on local Mesh; effect on RainMaker | Local Light Blink is RGB bytes + little-endian uint16 CCT + brightness byte + little-endian uint32 transition milliseconds + repeat-count byte. RainMaker effect is flattened `effect` plus tuning parameters. | Fully decoded static code; transport-specific command classes |
| `CC` | Local light mode | one byte: `01` color, `02` white temperature | Fully decoded static code, enum values, and normal room-controls call path |
| `CD` | Change provisioning mode | mode byte + little-endian uint32 timeout milliseconds | Static native code |
| `CE` | Response shared by Wi-Fi/provisioning flows | success/status byte, sometimes detail/error byte | Static native code |
| `CF` | Location | signed int32 latitude and longitude microdegrees, big-endian | Static code |
| `D1` | Missing device data | bit 0 timezone, bit 1 location, bit 2 solar cycle | Static callback code |
| `D2` | Combined white temperature and brightness | little-endian uint16 kelvin + percent byte + little-endian uint32 Unix time | Static code and bridge-emitted live control |

`D0` is Mesh network configuration, not power or an ordinary control. `CA AA`
is reached directly from the app's device-factory-reset path; it is
intentionally omitted from the protocol helper and every bridge API. A separate
empty-payload `CC` debug object also exists, but the supported room-control path
uses the typed one-byte mode selector and only that form is exposed here.

The native API also supports provisioning, deprovisioning, changing rooms,
removing a device from a room, reset-Mesh-network, proxy connection, scanning,
and per-device/room/broadcast command sends. Those management actions are not
needed for normal control and must not be invoked during protocol exploration.

### Pairing and reconciliation behavior

Pairing is a multi-stage transaction, not a single BLE write. The client:

1. scans separately for BLE Mesh and RainMaker devices;
2. provisions the first Mesh device and waits for its Wi-Fi response before
   continuing the remaining devices;
3. retries Wi-Fi delivery sequentially and tracks final success/failure states;
4. adds verified devices to the selected room and uploads the exported Mesh
   network plus device metadata to Home Group `custom_data`;
5. broadcasts timezone and location to the completed room; and
6. sends explicit white-mode and “Provisioning Done” commands, with behavior
   that includes a firmware-version comparison against `2.21.12`.

The app has cleanup paths for a deleted device during provisioning, a room
change during provisioning, native success followed by Dart-side cancellation,
and partially provisioned failures. It also prunes “ghost” devices that still
advertise as unprovisioned but exist in the local cache.

On startup, cloud RainMaker ownership is treated as the source of truth for
reconciliation, but the app is deliberately conservative with Mesh credentials:
it refuses a cloud import that would remove local devices merely because they
are absent from a cached cloud Mesh snapshot. It also preserves the existing
cloud Mesh if native export unexpectedly returns empty. These safeguards are
important to copy into any future management tool.

### Incoming status limitation

The Android 2.7.0 native callback handles provisioning/configuration traffic,
the `D1` missing-data report, and the `CE` response. Other vendor messages are
logged as unhandled. Ordinary power, brightness, temperature, color, and effect
state are therefore not decoded from Mesh by this build; the visible room state
is updated optimistically and cached. A bridge can be compatible with the
wire commands while still needing optimistic state or a separate read path.

There also appears to be a decompiled control-flow defect: two consecutive
branches compare the same `CE` message ID, and the first Wi-Fi-response branch
exits before the provisioning-response branch. This likely makes provisioning
mode result tracking unreachable in Android 2.7.0. It is static evidence, not a
claim about firmware or the iOS build.

## Espressif LAN local-control transport

RainMaker-capable nodes advertise `_esp_local_ctrl._tcp.` over mDNS. Oasis maps
the TXT `node_id` to the resolved host and port, keeps a per-node
proof-of-possession map, and uses Espressif Security1 for the current send path.
It posts encrypted bytes to:

```text
http://<resolved-host>:<port>/esp_local_ctrl/control
```

The plaintext before transport encryption is an Espressif
`LocalCtrlMessage/CmdSetPropertyValues` protobuf containing one `PropertyValue`.
That value is the complete UTF-8 JSON body supplied by Flutter. Success is the
protobuf response status `Success`; the bridge receives only a Boolean result.

This is a genuine local-LAN alternative to both BLE Mesh and the cloud, but it
requires the correct per-node proof-of-possession secret. It should not be
probed or logged casually. It may primarily serve RainMaker-native product
variants while the installed Ambient 2 lights use BLE Mesh; live discovery is
still needed to determine whether these two nodes advertise it.

A keys-only audit of the protected iOS preference/cache snapshot found no POP
or local-control field. It contains Mesh data and metadata, but that is a
different credential set. Obtaining LAN-local control would therefore require
a protected fresh API/runtime observation rather than deriving or guessing a
secret from the saved cache.

## RainMaker cloud and account model

The decoded API includes:

- `user/nodes/params` for ordinary parameter writes
- `user/nodes/cmd` for longer-running commands
- `user/node_group` for Home Group and room state
- `user/nodes/matter/data` for node-specific Matter commissioning data

The protected iOS cache contains one Home Group, one room, and the two installed
nodes. Both Home Group and room say `is_matter=false`. Matter data responses
contain `qr_code` and `manual_code`; requesting them can open a commissioning
window (`open_commissioning`/`open_fabric`). That is a pairing-state change and
must not happen without explicit approval.

## White light, color, and effects

Known white presets are 2000 K Candle, 2400 K Amber, 2800 K Glow, 3000 K Soft,
3500 K Neutral, and 4000 K Bright. Additional model constants include 2200,
2600, 3200, and 3600 K. The existing bridge's 2700–6500 K range does not match
the official preset range; changing it should follow safe physical validation.

Two live iOS preset taps confirmed that Amber sends `C5 60 09` and Bright sends
`C5 A0 0F`; the two payload bytes are simply Kelvin in little-endian order.
The brightness slider confirmed `C4` independently. Its first parameter is the
integer percent and the remaining four bytes are a little-endian Unix time. A
brightness interaction also reasserted power-on with `C3`, so a compatible UI
should expect brightness changes to imply an on state.

The hidden `/admin` route exposes diagnostic Light Set and Light Blink panels.
Only Light Set, Light Blink, and CCTB have implemented handlers; the listed
Logo Set and Logo Blink choices have no command handler in Android 2.7.0. A
protected live iOS Light Set test sent directly to selected remote nodes and
produced no BLE Mesh Access PDU. It used command `C6` with five normalized
channels: `red`, `green`, `blue`, `cold`, and `warm`. This is a useful direct
RainMaker control surface but should not be confused with ordinary room control,
which prefers BLE and then performs cloud reconciliation.

Light Blink is command `CB`. Its cloud object and byte payload contain `red`,
`green`, `blue`, `cct`, `brightness`, `transition_millis`, and `times`. The
11-byte order is RGB, little-endian uint16 CCT, brightness, little-endian uint32
transition milliseconds, then repeat count. The local form of C6 serializes only
the three RGB channels, each normalized value multiplied by 255 and truncated.
The cold/warm channels are retained in the RainMaker representation rather than
the local three-byte payload. This dual representation matches Oasis's broader
pattern of transport-specific encodings for one logical command.

Normal room controls precede/reconcile color and white changes with local `CC`
mode state: `01` selects color and `02` selects temperature. RGB values then use
local `C6`; white temperature uses `C5` or combined `D2`. This resolves the
earlier ambiguity around `CC` without treating it as RGB data itself.

`C7` is an ephemeral transition preview, not a schedule write. The Light Cycle
color editor supplies a target temperature, brightness, and 60,000-millisecond
duration; session teardown sends all three values as zero. Persistent Light
Cycle changes use the automation schema and room schedule command described
below, so bridge automations should not substitute repeated `C7` previews.

Android 2.7.0 defines two effects:

- Ocean: `flow`, `swell`, `warmth`, and `whitecap`, each 0–1.
- Fireplace: `base`, `min`, `max`, `jitter`, `gust_interval_ms`,
  `gust_depth_min`, `gust_depth_max`, and `warm` with client-side defaults and
  ranges.

RainMaker effect data is flat: `effect` and every supplied tuning parameter are
siblings in the same object. The live-tuning UI sends only the changed
parameter after initial setup. Cached room state stores `Effect` separately.
Its RainMaker command ID is `CB`, even though the local-Mesh `CB` class is Light
Blink. These are separate transport-specific command families, not a shared
payload. Android 2.7.0 contains no confirmed local-Mesh effect payload, so
effects must remain RainMaker-only unless a supported live capture establishes
one; a BLE opcode must not be guessed from the numeric overlap.

The protected iOS experiment cache explains why those controls are absent on
the installed app: `ble-mesh` is assigned `on`, while `effects`, `matter`,
`apple-home`, `oasis-remote`, and `new-tones` are assigned `off`. The live
Controls picker consequently exposes only the six white presets. This is a
server-assigned feature gate, not an undiscovered gesture or settings screen.

## Automations and LightCycle

The official “natural variation throughout the day” feature is not opaque: the
current cache contains the migrated LightCycle as ordinary, device-resident
automations. The complete schema and compatible update sequence are documented
in `OASIS_AUTOMATION_PROTOCOL.md`.

The device receives its full room schedule via remote command 2051, plus
timezone (2050 / BLE `C9`) and location (2049 / BLE `CF`). A device can report
which of timezone, location, and solar-cycle data is missing through `D1`.
This strongly indicates execution on the light rather than phone timers.

### Scene boundary

The room/Home Group model parses and re-serializes an `active_scene_ids` string
list, so Oasis has reserved backend state for scenes and compatibility code
must preserve it. In Android 2.7.0, however, every cross-reference to that field
is in model parsing or serialization. There is no lighting-scene picker,
activation command object, or device-send call site in this build. Flutter's
many `Scene`/`SceneBuilder` symbols are rendering-engine APIs and are unrelated.
Until a newer official client supplies a real activation path, scenes should be
treated as opaque preserved state rather than synthesized as device commands.

## Interoperability rules

1. Preserve unknown Home Group fields, especially `ble_mesh_config`.
2. Read/merge/write the official schedule instead of maintaining a parallel
   incompatible automation store.
3. Prefer confirmed device/room commands; do not expose guessed opcodes.
4. Treat Mesh keys, POP values, tokens, node IDs, and Matter setup data as
   secrets. Never put them in logs, argv, source, or chat.
5. Do not provision, deprovision, reset, change rooms, or open a Matter
   commissioning window as a diagnostic action.
6. Never expose or send `CA AA`; it is the confirmed device-factory-reset
   command.
7. Treat ordinary control state as optimistic until an authoritative readback
   mechanism is confirmed.

## Remaining high-value validation

- Capture one official Ocean/Fireplace change to identify the BLE effect
  opcode and payload if Oasis legitimately enables the `effects` assignment;
  do not modify the protected experiment cache to force it on.
- Capture a supported official RGB change to verify the C6 local/cloud
  reconciliation timing and resulting cached room state.
- Observe whether either installed Ambient 2 advertises
  `_esp_local_ctrl._tcp` and, if so, whether the official cache supplies the
  corresponding POP through a protected path.
- Compare iOS 2.7.1 behavior with the nearby Android 2.7.0 callback logic.
- Perform a read-only fresh Home Group fetch before any future schedule write.
- Validate the official 2000–4000 K range physically before changing the
  bridge and Home Assistant entity limits.
