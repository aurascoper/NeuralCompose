# NeuralCompose Android Client: Build Prompt for Hermes Agent on Pixel 8a

> Execute this prompt in Termux on the Pixel 8a. The agent (you) has terminal,
> file editing, search, and code execution tools. The model is minimax-m3:cloud
> via Ollama cloud API. Work in order. Each stage is independently testable.

---

## Context

NeuralCompose is a privacy-first macOS BCI application running on an M4 Mac at
home. It processes EEG from a Muse headband through BrainFlow, Core ML (ANE),
and MLX, producing real-time intent classifications, channel health, and 3D
visualizations. The Mac is on a Tailscale VPN at `100.94.124.23` (Pixel 8a)
and `100.105.8.22` (M4 Mac).

Your job: build an Android client app on this Pixel 8a that connects to the
NeuralCompose M4 server over Tailscale and displays live pipeline state. The
app is a thin client: all heavy processing stays on the Mac. The Pixel does
UI rendering, voice dictation, and local storage only.

## Environment

- Device: Google Pixel 8a, 8GB RAM, Tensor G3, 128GB storage
- OS: Android, Termux (Linux userland, no root)
- Python: 3.13 (Termux native)
- Node.js: needs installing
- Tailscale: installed, tailnet IP `100.94.124.23`
- Hermes Agent: installed in venv at `~/.hermes/hermes-agent/venv`
- Model: minimax-m3:cloud via Ollama cloud API

## Hard constraints

1. **No Android SDK.** Termux cannot run `aapt2`, `d8`, or the Android build
   tools. APK builds go through Expo EAS Build (cloud service, free tier:
   30 builds/month). No local APK compilation.
2. **No root.** No `sudo`, no Docker, no kernel modules. Termux userland only.
3. **8GB RAM.** Metro bundler + Expo Go + Hermes Python process must not run
   simultaneously during builds. Cycle: Hermes edits, Metro restarts, Expo Go
   reloads. Close Hermes while testing in Expo Go if memory pressure appears.
4. **Expo Go is the renderer.** Install Expo Go from the Play Store. The dev
   server (Metro) runs in Termux on `localhost:8080`. Expo Go connects to it.
   Hot reload works. No emulator needed.
5. **No local inference.** The cloud LLM is the reasoning engine. The Pixel
   is the terminal + dev server + renderer. No local model weights.
6. **The M4 server does not exist yet.** Build against mock data fixtures
   matching the API contract below. The real server is a separate PR on the
   M4 (Claude Code's job). When it's ready, swap the mock URL for the
   Tailscale URL.

---

## Part 1: Environment setup

### 1.1 Install Node.js and Expo

```bash
pkg install nodejs git
node --version    # confirm v20+
npm install -g expo-cli
expo-cli --version
```

If `expo-cli` global install fails (RAM or permission), use `npx expo`
instead: it downloads on first use and doesn't require a global install.

### 1.2 Bootstrap the project

```bash
cd ~
npx create-expo-app neuralcompose-client
cd neuralcompose-client
npx expo start
```

Open Expo Go on the Pixel. Scan the QR code or open the URL. Confirm the
default "Welcome to Expo" screen renders. If it does, the dev loop works.

### 1.3 Install dependencies

```bash
npx expo install react-native-chart-kit react-native-svg
npx expo install @react-native-async-storage/async-storage
npx expo install expo-av
npx expo install expo-network
```

If any install fails due to RAM, install them one at a time with
`--max-workers=1`.

---

## Part 2: API contract

The M4 server (not yet built) will expose these endpoints. Build the client
against mock fixtures matching these schemas. When the server is ready,
replace the mock URL with `http://100.105.8.22:8081` (M4's Tailscale IP,
port to be confirmed).

### 2.1 GET /api/diagnostics

Returns `StreamDiagnostics` as JSON:

```json
{
  "transport": "OSC (Mind Monitor)",
  "sampleRate": 256.0,
  "packetsReceived": 15432,
  "packetsDropped": 3,
  "packetLossEstimate": null,
  "packetJitterMillis": 2.4,
  "lastInterArrivalMillis": 3.9,
  "lastHeartbeat": "2026-07-23T18:30:00Z",
  "boundPort": 5000,
  "localInterfaceName": "utun3"
}
```

### 2.2 GET /api/health

Returns an array of `ChannelHealthState`:

```json
[
  {"channel": "TP9",  "status": "healthy",   "rms": 162.5, "samples": 77966, "timestamp": 305.2, "lastSampleWallClock": 1783738346.0},
  {"channel": "AF7",  "status": "healthy",   "rms": 176.6, "samples": 77966, "timestamp": 305.2, "lastSampleWallClock": 1783738346.0},
  {"channel": "AF8",  "status": "saturated", "rms": 971.0, "samples": 77966, "timestamp": 305.2, "lastSampleWallClock": 1783738346.0},
  {"channel": "TP10", "status": "healthy",   "rms": 146.4, "samples": 77966, "timestamp": 305.2, "lastSampleWallClock": 1783738346.0}
]
```

### 2.3 GET /api/classifier

Returns the latest `IntentPrediction`:

```json
{
  "intent": "rest",
  "confidence": 0.89,
  "distribution": {"rest": 0.89, "jawClench": 0.04, "singleBlink": 0.03, "doubleBlink": 0.02, "select": 0.02},
  "windowSequence": 15432,
  "endTimestamp": 305.2
}
```

### 2.4 GET /api/pipeline-mode

Returns the current `PipelineMode`:

```json
{
  "source": "oscRemote",
  "sourceProfile": "OSC Remote (network)",
  "classifier": "coreML",
  "predictor": "mlx",
  "transportDetail": "UDP 5000 · utun3",
  "isFullyLive": false,
  "substitutionSummary": "EEG: OSC Remote (network) (UDP 5000 · utun3)"
}
```

### 2.5 WebSocket /api/eeg/stream

Streams `EEGSample` objects as JSON, one per ~4ms (256 Hz):

```json
{"timestamp": 305.21, "channels": [12.5, -34.0, 0.0, 999.75]}
```

Channel order: TP9, AF7, AF8, TP10.

---

## Part 3: Mock data layer

Create `src/mock/` with fixture files matching each API endpoint above.
Create a `MockApiClient` class that returns these fixtures with simulated
delay and jitter (e.g., incrementing `packetsReceived` every second, adding
random noise to EEG samples).

The `MockApiClient` must conform to the same interface as the real
`ApiClient` (defined next). The app should switch between them via a
single config flag: `USE_MOCK = true` in `src/config.ts`.

When the M4 server is ready, set `USE_MOCK = false` and point
`SERVER_URL` at the Tailscale IP. Nothing else changes.

---

## Part 4: App architecture

```
src/
  config.ts          : SERVER_URL, USE_MOCK, poll intervals
  api/
    ApiClient.ts      : interface for all API calls
    MockApiClient.ts  : mock implementation with fixtures
    LiveApiClient.ts  : real implementation, fetch from M4 over Tailscale
  screens/
    OverviewScreen.tsx: pipeline mode + privacy indicator + diagnostics
    EEGScreen.tsx     : real-time 4-channel EEG trace
    HealthScreen.tsx  : channel health badges (TP9/AF7/AF8/TP10)
    ClassifierScreen.tsx: intent prediction + confidence bar + distribution
    DreamJournalScreen.tsx: voice/text dream report entry + local storage
  components/
    PrivacyBadge.tsx  : shows active source + transport detail
    ChannelBadge.tsx  : single channel health indicator
    EEGTrace.tsx       : single-channel waveform renderer
    ConfidenceBar.tsx  : horizontal bar for classifier confidence
    StaleIndicator.tsx : "no data Ns" warning
  hooks/
    useDiagnostics.ts  : polls /api/diagnostics every 1s
    useHealth.ts       : polls /api/health every 1s
    useClassifier.ts   : polls /api/classifier every 0.5s
    useEEGStream.ts    : WebSocket subscription to /api/eeg/stream
    usePipelineMode.ts : polls /api/pipeline-mode every 2s
  storage/
    DreamJournal.ts    : AsyncStorage CRUD for dream reports
  App.tsx              : tab navigator, 5 screens
```

### Navigation

Bottom tab bar with 5 tabs: Overview, EEG, Health, Classifier, Journal.

### Polling strategy

Each hook polls independently. Use `setInterval` with cleanup on unmount.
For the EEG WebSocket, use `reconnecting-websocket` (npm package) with
exponential backoff. On reconnect failure after 3 attempts, show a
"Stream disconnected" banner and fall back to the last cached data.

---

## Part 5: Screens

### 5.1 OverviewScreen

Top: privacy badge showing active source, transport detail, and whether
the pipeline is fully live. Below: a diagnostics panel with packets
received, packets dropped, jitter, last heartbeat (relative time: "2s ago"),
bound port, and interface name. If `lastHeartbeat` is more than 5 seconds
old, show the stale indicator in orange.

### 5.2 EEGScreen

Four stacked waveforms (TP9, AF7, AF8, TP10), scrolling left-to-right at
256 Hz. Use `react-native-chart-kit` or a custom SVG renderer. Show the
last 5 seconds of data (1280 samples per channel). Color-code: TP9/TP10
in blue, AF7/AF8 in green. If the WebSocket is disconnected, show a
placeholder with "Connecting..." and the last data frozen.

Y-axis: auto-scaling per channel, with the range label on the right
(µV). X-axis: time in seconds, relative to stream start.

### 5.3 HealthScreen

Four `ChannelBadge` components in a vertical list, one per channel. Each
badge shows: channel name, status (healthy/saturated/dead/unknown, color-
coded green/red/gray/blue), RMS value in µV, sample count, and a staleness
indicator if `lastSampleWallClock` is more than 2 seconds old. Mirror the
macOS `ChannelHealthBadge` behavior.

### 5.4 ClassifierScreen

Top: the predicted intent as large text ("Rest", "Jaw Clench", "Single
Blink", "Double Blink", "Select"). Below: a horizontal confidence bar
(0-100%). Below that: the full distribution as 5 stacked horizontal bars,
one per intent class, width proportional to probability. If the classifier
hasn't produced a prediction yet (stale > 5s), dim the screen and show
"Classifier idle."

### 5.5 DreamJournalScreen

Top: a text input field for dream report entry. Below the input: a
microphone button using `expo-av` for voice recording. On stop, the audio
is saved locally (AsyncStorage or filesystem). Below: a scrollable list of
past dream reports, each with timestamp, text (if transcribed), and audio
playback button. Entries are stored locally only: no sync to the M4 in
this version.

If voice transcription is needed (future), it would go through the M4's
MLX LLM. For now, voice recordings are stored as audio files with manual
text entry.

---

## Part 6: Build and distribute

### 6.1 Test on device

```bash
npx expo start
```

Open Expo Go. Verify all 5 screens render with mock data. Verify the EEG
trace scrolls. Verify the dream journal saves and retrieves entries.

### 6.2 Build APK via EAS

```bash
npm install -g eas-cli
eas login                    # create an Expo account if needed
eas build:configure
eas build --platform android --profile preview
```

The `preview` profile produces a standalone APK (not a Play Store bundle).
Download the APK from the EAS dashboard and install it on the Pixel
(`adb install` if `adb` is available, or just open the APK file).

### 6.3 Configuration for production

In `app.json`:
- `name`: "NeuralCompose Client"
- `slug`: "neuralcompose-client"
- `version`: "0.1.0"
- `icon`: a placeholder for now (can be replaced later)
- `android.package`: "com.aurascoper.neuralcompose"

In `eas.json`:
- `preview`: builds APK, internal distribution
- `production`: builds AAB for Play Store (future)

---

## Part 7: M4 server integration (when ready)

When the M4's thin HTTP server is built (separate Claude Code PR), update
`src/config.ts`:

```typescript
export const USE_MOCK = false;
export const SERVER_URL = "http://100.105.8.22:8081"; // M4 Tailscale IP
export const EEG_WS_URL = "ws://100.105.8.22:8081/api/eeg/stream";
```

Test over Tailscale:
1. Confirm `tailscale status` shows the M4 as online
2. Open the app, verify OverviewScreen shows live diagnostics
3. Verify EEG trace shows real Muse data
4. Verify channel health updates within 2s of first packet
5. Verify classifier produces non-uniform predictions after 30s

---

## Part 8: Constraints and gotchas

1. **RAM pressure.** If Metro + Expo Go OOMs, kill Metro
   (`Ctrl+C` in Termux), close Expo Go, restart Metro, reopen Expo Go.
   The Pixel 8a has 8GB but Android's background processes eat 2-3GB.

2. **Termux process limits.** Android kills background processes
   aggressively. If Termux is killed while Metro is running, use
   `termux-wake-lock` to prevent it:
   ```bash
   termux-wake-lock
   ```
   Release it when done: `termux-wake-unlock`.

3. **WebSocket in React Native.** The default `WebSocket` global works in
   React Native, but `reconnecting-websocket` needs a polyfill for
   `WebSocket` if the version expects a browser implementation. Test
   the WebSocket connection early with a mock server running in Termux
   (`python3 -m http.server` won't do WebSocket; use `websockets` Python
   package for a quick mock WS server).

4. **Chart rendering performance.** `react-native-chart-kit` uses SVG
   rendering which can be slow for 1280 data points at 30fps. If it
   stutters, downgrade to 2 seconds of data (512 samples) or use a
   custom Canvas renderer via `react-native-canvas`.

5. **Audio recording permissions.** `expo-av` needs
   `RECORD_AUDIO` permission. In Expo Go this is handled automatically.
   In a standalone build, add it to `app.json` under
   `android.permissions`.

6. **Tailscale in Termux.** Tailscale runs as an Android app, not inside
   Termux. Termux processes can reach Tailscale IPs because the Android
   VPN routes all traffic through Tailscale. No special Termux config
   needed. Verify with `curl http://100.105.8.22:8081/api/diagnostics`
   when the M4 server is up.

7. **No claude-mind-mcp on Android.** The Swift-based MCP server won't
   compile in Termux. Memory bank and recall are unavailable on the
   Pixel. Use AsyncStorage for local persistence instead.

8. **No prose-craft gate on Android.** The `pcr` Rust binary may
   compile via Termux's Rust toolchain (`pkg install rust`), but this
   is untested. If you need the prose-craft gate, test `pcr` compilation
   separately before relying on it.

---

## Part 9: Execution order

1. Install Node + Expo (Part 1)
2. Bootstrap project, confirm Expo Go renders (Part 1.2)
3. Write mock data fixtures (Part 3)
4. Write ApiClient interface + MockApiClient (Part 3)
5. Build OverviewScreen with privacy badge + diagnostics (Part 5.1)
6. Build HealthScreen with channel badges (Part 5.3)
7. Build ClassifierScreen with confidence bars (Part 5.4)
8. Build EEGScreen with scrolling waveforms (Part 5.2)
9. Build DreamJournalScreen with text + audio (Part 5.5)
10. Wire up tab navigation (Part 4)
11. Test all screens with mock data (Part 6.1)
12. Build APK via EAS (Part 6.2)
13. Document the Tailscale integration steps (Part 7)

Each step is independently testable. Do not proceed to the next until
the current one renders correctly in Expo Go.

---

## Part 10: What this app is NOT

- It is not a standalone NeuralCompose. It does not do EEG processing,
  classification, or LLM inference on the Pixel. All processing is on
  the M4.
- It is not a Mind Monitor replacement. Mind Monitor handles Muse BLE
  acquisition and OSC streaming. This app is a viewer for the M4's
  pipeline output.
- It is not a production medical device. It is a research prototype
  client for monitoring a BCI pipeline remotely.
- It does not sync dream reports to the M4 in this version. Local
  storage only. Sync is a future feature.
- It does not include the 3D SceneKit workspace. That requires WebGL
  or Three.js integration, which is a separate scope. The EEG trace
  is 2D only in this version.