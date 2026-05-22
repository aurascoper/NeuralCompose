# Hardware setup

NeuralCompose has been written against three Muse headband revisions plus a
synthetic stream. You do not need any hardware to run the demo; this document
exists for when you want to use a real device.

## Supported devices

Native BLE vs **BLED112 USB dongle** is a first-class distinction. Same Muse
hardware, different BrainFlow board ID, different connection parameters —
the profile picks both.

| Profile               | Env value          | BrainFlow Board ID                | Notes                                                                   |
|-----------------------|--------------------|-----------------------------------|-------------------------------------------------------------------------|
| `.museTwoNativeBLE`   | `muse2`            | `MUSE_2_BOARD` = 38               | Muse 2 over Apple's BLE stack.                                          |
| `.museTwoBLED`        | `muse2-bled`       | `MUSE_2_BLED_BOARD` = 22          | Muse 2 over a BLED112 dongle.                                           |
| `.museSNativeBLE`     | `muses`            | `MUSE_S_BOARD` = 39               | Muse S over native BLE.                                                 |
| `.museSBLED`          | `muses-bled`       | `MUSE_S_BLED_BOARD` = 21          | Muse S over a BLED112 dongle.                                           |
| `.museSAthena`        | `athena`           | `MUSE_S_ANTHENA_BOARD` = 60       | New dedicated Athena board, BrainFlow 5.22+. **Verify integer on your install.** |
| `.synthetic`          | `synthetic`        | `SYNTHETIC_BOARD` = -1            | BrainFlow's built-in synthetic generator.                               |
| `.playback`           | `playback`         | n/a                               | Reads a CSV produced by an earlier `Recordings/` run.                   |

These integers are *implementation detail of* `MuseBoardProfile.swift`. After a
BrainFlow upgrade, sanity-check them with:

```swift
import BCIEEG
BrainFlowService.debugDumpKnownBoards()
```

which exercises each ID against your installed BrainFlow and logs the channel
count and sample rate it reports for each candidate.

## Bluetooth transport

- **Native BLE.** Best for Muse 2 and Muse S Athena on Apple Silicon. Pair the
  device once via System Settings → Bluetooth so macOS knows it exists, then
  let BrainFlow connect by name/MAC.
- **BLED112 dongle (e.g. ASUS USB-BT500).** Required if you've had stability
  issues with native BLE, or for the BLED-only boards. Set `serial_port` on
  `BrainFlowInputParams`, or export `NEURALCOMPOSE_MUSE_SERIAL=/dev/cu.usbmodem*`
  before launch — the dongle path is honored automatically for the
  `*BLED` profiles via `MuseBoardProfile.usesBLEDDongle`.

Both wirings are confined to `BrainFlowService.makeParamsJSON()` and opaque
to the rest of the codebase.

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
