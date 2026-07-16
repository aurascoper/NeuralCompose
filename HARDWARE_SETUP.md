# Hardware setup

NeuralCompose has been written against three Muse headband revisions plus a
synthetic stream. You do not need any hardware to run the demo; this document
exists for when you want to use a real device.

## Supported devices

Native BLE vs **BLED112 USB dongle** is a first-class distinction. They are
*different connection methods*, not a hardware-vs-software detail:

- **Native BLE.** macOS' built-in Bluetooth Low Energy stack. Works through
  whatever BLE radio macOS happens to be using — the internal one in Apple
  Silicon Macs, or a generic USB-BT adapter such as an ASUS USB-BT500. The
  generic adapter just extends the native stack; it is **not** a BLED112.
- **BLED112 (Silicon Labs / Bluegiga BLED112).** A specific USB BLE dongle
  that speaks a proprietary serial protocol. BrainFlow has dedicated board
  IDs for it (`MUSE_*_BLED_BOARD`). Modern BrainFlow (5.22+) considers the
  BLED boards deprecated and recommends native BLE.

| Profile               | Env value          | BrainFlow Board ID            | Connection method                                       |
|-----------------------|--------------------|-------------------------------|---------------------------------------------------------|
| `.museTwoNativeBLE`   | `muse2`            | `MUSE_2_BOARD` = 38           | Native BLE (built-in or generic adapter, e.g. USB-BT500). |
| `.museTwoBLED`        | `muse2-bled`       | `MUSE_2_BLED_BOARD` = 22      | BLED112 dongle. Set `NEURALCOMPOSE_MUSE_SERIAL`.         |
| `.museSNativeBLE`     | `muses`            | `MUSE_S_BOARD` = 39           | Native BLE.                                              |
| `.museSBLED`          | `muses-bled`       | `MUSE_S_BLED_BOARD` = 21      | BLED112 dongle. Set `NEURALCOMPOSE_MUSE_SERIAL`.         |
| `.museSAthena`        | `athena`           | `MUSE_S_ATHENA_BOARD` = 67    | Native BLE only (BLED variants do not exist for Athena). |
| `.synthetic`          | `synthetic`        | `SYNTHETIC_BOARD` = -1        | BrainFlow's built-in synthetic generator.                |
| `.playback`           | `playback`         | n/a                           | Reads a CSV produced by an earlier `Recordings/` run.    |

> **Naming note.** BrainFlow's 5.22 *announcement post* spells the Athena
> constant `MUSE_S_ANTHENA_BOARD`. The actual C++ enum in
> `src/utils/inc/brainflow_constants.h` is `MUSE_S_ATHENA_BOARD = 67`. We
> follow the source enum.

These integers are *implementation detail of* `MuseBoardProfile.swift`.
After a BrainFlow upgrade, verify them against the compiled BrainFlow enum
*without opening any hardware session* by running:

```swift
import BCIEEG

switch BrainFlowService.verifyBoardIDsAgainstBridge() {
case .matched:             print("MuseBoardProfile matches installed BrainFlow")
case .bridgeUnavailable:   print("Bridge stubbed — verification skipped")
case .mismatched(let xs):  xs.forEach { print("DRIFT: \($0)") }
}
```

The verifier compares `MuseBoardProfile.brainFlowBoardID` against the
`BoardIds::*` integers your linked BrainFlow exposes via the bridge's
`bci_bridge_board_id_*` getters. No BLE permission required, no Muse
required.

## Bluetooth transport

- **Native BLE.** Best for Muse 2, Muse S, and Muse S Athena on Apple
  Silicon. Pair the device once via System Settings → Bluetooth so macOS
  knows it exists, then let BrainFlow connect by name/MAC. Do **not** set
  `serial_port` for native-BLE profiles.

- **BLED112 dongle.** Required only for the explicit `*BLED` profiles. Set
  `NEURALCOMPOSE_MUSE_SERIAL=/dev/cu.usbmodem*` before launch — the dongle
  serial path is honored automatically for the BLED profiles via
  `MuseBoardProfile.usesBLEDDongle`. Athena does **not** have a BLED variant
  in current BrainFlow.

### Athena startup options

For `.museSAthena`, BrainFlow expects startup options via
`BrainFlowInputParams.other_info`. We default to
`preset=p1041;low_latency=true` (one of the three Athena presets), and let
you override with `NEURALCOMPOSE_BRAINFLOW_OTHER_INFO`:

```bash
NEURALCOMPOSE_BRAINFLOW_OTHER_INFO='preset=p1042;low_latency=true' \
    ./Scripts/run-synthetic.sh --profile athena
```

### Multi-device disambiguation

If multiple Muse devices are in range, pin one by either MAC address or
printed serial number — BrainFlow's Muse / Muse S / Athena docs accept both
as optional selectors on `BrainFlowInputParams`:

```bash
# Selector A — MAC address (becomes BrainFlowInputParams.mac_address)
NEURALCOMPOSE_MUSE_MAC=AA:BB:CC:DD:EE:FF \
    ./Scripts/run-synthetic.sh --profile athena

# Selector B — serial number (becomes BrainFlowInputParams.serial_number)
NEURALCOMPOSE_MUSE_SERIAL_NUMBER=MUSE-XXXX \
    ./Scripts/run-synthetic.sh --profile athena
```

You can set both; BrainFlow uses whichever it can match. Honored across all
profiles. (Note: `NEURALCOMPOSE_MUSE_SERIAL` is something different — that
points at a `/dev/cu.usbmodem*` *serial port*, used by the BLED112 profiles.)

### Discovery timeout

`BrainFlowService` sends BrainFlow a 20s BLE discovery timeout by default —
override with `NEURALCOMPOSE_MUSE_DISCOVERY_TIMEOUT` (seconds):

```bash
NEURALCOMPOSE_MUSE_DISCOVERY_TIMEOUT=30 ./Scripts/run-muse-s.sh
```

BrainFlow's own default, when this field is left at 0, is a bare **6
seconds** (`muse.cpp`'s `prepare_session()`) — often too short for macOS
CoreBluetooth/SimpleBLE discovery on a cold adapter, and well under the
30–60s advertising window in the checklist below. If connection attempts
are all failing at roughly the same short duration with 0 samples (check
`log show --predicate 'subsystem == "com.neuralcompose"'` for
`Live stream interrupted (0 samples)`), this is the first thing to try.

All wiring is confined to `BrainFlowService.makeParamsJSON()` and opaque to
the rest of the codebase.

## Remote transport: OSC (Mind Monitor)

`MindMonitorOSCStream` is a fourth `EEGStreaming` conformer, alongside
BrainFlow, synthetic, and playback — but the only one that touches the
network at runtime. Use it when the Muse is paired to a phone (running
[Mind Monitor](https://mind-monitor.com)) instead of directly to this Mac —
e.g. wearing the headband away from your desk while this Mac does the
processing at home.

**This must run over a private VPN** (Tailscale, WireGuard, ZeroTier)
between the phone and this Mac. OSC has no authentication or encryption of
its own — never port-forward this to the public internet.

1. Install Tailscale (or another VPN) on both the phone and this Mac, and
   confirm they can reach each other.
2. Find this Mac's VPN IP (Tailscale: `tailscale ip -4`).
3. In Mind Monitor's settings: **OSC Host** = this Mac's VPN IP,
   **OSC Streaming** = on, **OSC Port** = `5000` (or your choice).
4. On this Mac:
   ```bash
   ./Scripts/run-osc-remote.sh              # listens on port 5000
   ./Scripts/run-osc-remote.sh --port 6000  # or a different port
   ```

Only `/muse/eeg` is decoded today (`MindMonitorDecoder`) — other Mind
Monitor addresses (`/muse/acc`, `/muse/gyro`, `/muse/batt`, ...) are
received and silently ignored, not errors. There's no packet-sequence
numbering in Mind Monitor's OSC stream, so `StreamDiagnostics.packetLossEstimate`
stays `nil` rather than reporting a number that isn't really measurable;
jitter and last-heartbeat are computed from local arrival timing instead.

The privacy banner shows the bound UDP port and (once a packet has arrived
and the connection's path resolves) the local network interface it came in
on, e.g. "EEG: OSC Remote (network) (UDP 5000 · utun3)" — a quick sanity
check that traffic is actually arriving over your VPN interface, not some
other one. This is informational only; the VPN itself is still what keeps
unwanted traffic out, not this display.

Binding is to `0.0.0.0` (all interfaces) — that's necessary, not a bug: a
VPN interface's IP isn't known ahead of time, so the listener has to bind
broadly to receive on whatever interface Tailscale creates. The actual
security boundary is "only devices on your VPN can reach this port," which
is the VPN's job, not the app's — see `MindMonitorOSCStream`'s doc comment.

## Installing BrainFlow

NeuralCompose links BrainFlow as a system library, not as a SwiftPM package.
There is no Homebrew formula for BrainFlow at the time of writing
(`brew search brainflow` returns nothing) — build from source:

```bash
git clone https://github.com/brainflow-dev/brainflow.git ~/Developer/brainflow
cd ~/Developer/brainflow && tools/build.sh
```

For native-BLE Muse support (Muse S, Muse S Athena) you also need
`-DBUILD_BLE=ON` when configuring the CMake build; see
[brainflow.readthedocs.io](https://brainflow.readthedocs.io) for the full
flag list. The `compiled/` directory afterward should contain
`libBoardController.dylib`, `libMuseLib.dylib`, and the matching SimpleBLE
dylibs.

After installation, rebuild NeuralCompose:

```bash
./Scripts/build.sh --with-brainflow
```

The script auto-detects BrainFlow at `~/Developer/brainflow` (override with
`--brainflow-path=…` or `BRAINFLOW_ROOT`). On success it copies BrainFlow's
runtime dylibs next to the NeuralCompose binary in `.build/<config>/` so
they resolve at launch.

## Sanity check

With BrainFlow installed and the Muse paired:

```bash
./Scripts/run-synthetic.sh --profile muses          # Muse S over native BLE
./Scripts/run-synthetic.sh --profile muses-bled     # Muse S over BLED dongle
./Scripts/run-synthetic.sh --profile athena         # Muse S Athena
```

You should see the privacy indicator switch from "Synthetic" to the chosen
profile name, the channel count update to 4, and the intent classifier start
firing predictions within ~2 seconds (one full windowing period).

## Native BLE smoke test

For Muse S native BLE (requires BrainFlow built with `-DBUILD_BLE=ON`):

```bash
./Scripts/build.sh --with-brainflow
./Scripts/run-muse-s.sh
```

With serial number (if multiple Muse devices nearby):

```bash
NEURALCOMPOSE_MUSE_SERIAL_NUMBER="MUSE-6018-MB9D-a715" \
./Scripts/run-muse-s.sh
```

### Pre-test checklist

Before each hardware test:

1. Quit competing apps (Muse, Mind Monitor, Bluetooth connections)
2. Power-cycle Muse S (off → on, wait for LED to pulse)
3. Keep within a few feet of the Mac, off charger
4. Run NeuralCompose within the advertising window (~30–60s)

### Troubleshooting device discovery

- **SimpleBLE missing?** Rebuild BrainFlow with `-DBUILD_BLE=ON` flag
- **Adapter found but device not found?** Reset macOS Bluetooth: `sudo pkill bluetoothd`
- **Want to test BrainFlow directly?** Run the Python test in the prompts above
- **Got "Failed to find Muse Device"?** Device may be off, out of range, or held by another app

## Falling back

If BrainFlow returns an error at any point during streaming, `BrainFlowService`
catches it, emits one `BCIError.streamFailed` on its bounded channel, and the
app's view model switches to `SyntheticEEGStream`. The UI's privacy banner
turns amber and explains the fallback. The session does not crash.
