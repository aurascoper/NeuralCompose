# Hardware setup

NeuralCompose has been written against three Muse headband revisions plus a
synthetic stream. You do not need any hardware to run the demo; this document
exists for when you want to use a real device.

## Supported devices

| Profile                | BrainFlow Board ID | Notes                                                  |
|------------------------|--------------------|--------------------------------------------------------|
| `museTwo`              | 22                 | Muse 2, classic BLE protocol.                          |
| `museS`                | 39                 | Muse S, first-gen.                                     |
| `museSAthena`          | 51                 | Muse S Athena, newer firmware + updated BLE protocol.  |
| `synthetic`            | -1                 | BrainFlow's built-in synthetic generator.              |
| `playback`             | n/a                | Reads a CSV produced by an earlier `Recordings/` run.  |

These IDs are the *canonical* BrainFlow integers as of brainflow 5.x. They are
**not** referenced anywhere in the functional layers — everything goes through
`MuseBoardProfile`. If BrainFlow renumbers a board, change the mapping in
`Sources/BCICore/Models/MuseBoardProfile.swift` only.

## Bluetooth transport (Muse S Athena)

Muse S Athena uses a newer BLE protocol that, on macOS, can be flaky over
the built-in Bluetooth stack. We use a dedicated **ASUS USB-BT500** dongle as
an OS-level serial-over-USB transport for stability. Treat this as a system
configuration concern: you may need to enable the alternative Bluetooth
transport in BrainFlow's `BrainFlowInputParams.serial_port` setting before the
board connects.

This wiring is confined to `BrainFlowService.connect(profile:options:)` and is
opaque to the rest of the codebase.

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
./Scripts/run-synthetic.sh --profile museS
```

You should see the privacy indicator switch from "Synthetic" to "Muse S",
the channel count update to 4, and the intent classifier start firing
predictions within ~2 seconds (one full windowing period).

## Falling back

If BrainFlow returns an error at any point during streaming, `BrainFlowService`
catches it, emits one `BCIError.streamFailed` on its bounded channel, and the
app's view model switches to `SyntheticEEGStream`. The UI's privacy banner
turns amber and explains the fallback. The session does not crash.
