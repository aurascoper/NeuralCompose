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

If multiple Muse devices are in range, pin one by MAC address with
`NEURALCOMPOSE_MUSE_MAC=AA:BB:CC:DD:EE:FF` — this becomes
`BrainFlowInputParams.mac_address` and is honored across all profiles.

All wiring is confined to `BrainFlowService.makeParamsJSON()` and opaque to
the rest of the codebase.

## Installing BrainFlow

NeuralCompose links BrainFlow as a system library, not as a SwiftPM package.

```bash
# Homebrew (preferred)
brew install brainflow

# Or build from source — https://brainflow.readthedocs.io
git clone https://github.com/brainflow-dev/brainflow.git
cd brainflow && tools/build.sh
```

After installation, rebuild NeuralCompose with the bridge enabled:

```bash
swift build \
  -Xcc -DBCI_BRAINFLOW_AVAILABLE=1 \
  -Xcc -I/opt/homebrew/include \
  -Xlinker -L/opt/homebrew/lib \
  -Xlinker -lBrainflow \
  -c release
```

Or use `Scripts/build.sh --with-brainflow`, which expands these flags for you.

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

## Falling back

If BrainFlow returns an error at any point during streaming, `BrainFlowService`
catches it, emits one `BCIError.streamFailed` on its bounded channel, and the
app's view model switches to `SyntheticEEGStream`. The UI's privacy banner
turns amber and explains the fallback. The session does not crash.
