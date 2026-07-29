# NeuralCompose Android Client

Thin Android viewer for the macOS NeuralCompose BCI pipeline. Streams live EEG,
channel health, classifier predictions, and pipeline mode from the M4 Mac server
over Tailscale. No on-device inference. No cloud sync. **Local-only dream journal.**

Built with **Expo SDK 57.0.8** + **React Native 0.86** on a Pixel 8a (Android 16)
in Termux. No Android SDK required — APK builds go through EAS Build.

---

## Quick start

```sh
cd ~/neuralcompose-client
npx expo start
```

Then open Expo Go on the Pixel and scan the QR code (or press `i` for the iOS
Simulator — see `docs/ios-client.md`). The app launches in **MOCK** mode (the
green pill in the top-right says `MOCK`) and renders all 6 tabs with synthetic
data — no M4 server needed.

To cut over to the real M4 server, see **Tailscale cutover** below.

---

## What's in here

```
src/
  config.ts                # USE_MOCK toggle, SERVER_URL, EEG_WS_URL, poll intervals
  theme.ts                 # dark palette + spacing tokens
  types/api.ts             # API contract types (single source of truth)
  api/
    ApiClient.ts           # interface both clients implement
    MockApiClient.ts       # in-memory simulation: 250Hz EEG, intent cycle, jitter
    LiveApiClient.ts       # fetch + WebSocket against the M4 over Tailscale
    index.ts               # exports the wired `apiClient` based on USE_MOCK
  mock/
    fixtures.ts            # exact JSON from the prompt's API contract
  hooks/
    useDiagnostics.ts      # polls /api/diagnostics
    useHealth.ts           # polls /api/health
    useClassifier.ts       # polls /api/classifier
    usePipelineMode.ts     # polls /api/pipeline-mode
    useEEGStream.ts        # subscribes to /api/eeg/stream WebSocket, rolling buffer
    useNow.ts              # 1Hz wall clock for relative timestamps
  components/
    PrivacyBadge.tsx       # top-of-Overview banner: source, transport, live/substituted
    ChannelBadge.tsx       # single channel health card
    ConfidenceBar.tsx      # horizontal probability bar
    StaleIndicator.tsx     # orange "no data Ns" pill
    EEGTrace.tsx           # custom polyline waveform (no SVG, no chart-kit)
  screens/
    OverviewScreen.tsx     # privacy + diagnostics panel
    HealthScreen.tsx       # 4 channel badges
    ClassifierScreen.tsx   # dominant intent + distribution
    EEGScreen.tsx          # 4 stacked waveforms
    DreamJournalScreen.tsx # text + voice entry, AsyncStorage-backed
  storage/
    DreamJournal.ts        # AsyncStorage CRUD for dream entries
App.tsx                    # NavigationContainer + bottom tab navigator
```

---

## Screens (matching Part 5 of the prompt)

| Tab       | What it does                                                                                                                                                            |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Overview  | Privacy badge (live vs substituted, classifier/predictor kind, transport detail) + diagnostics panel (packets, jitter, last heartbeat relative time, port, interface) |
| EEG       | Four stacked waveforms TP9/AF7/AF8/TP10, scrolling left-to-right, ~30fps render of last 5s (1280 samples) of a 256Hz stream. Custom polyline — no SVG dependency.        |
| Health    | Four ChannelBadge components. Color-coded healthy/saturated/dead/unknown. Stale sample (>2s) → orange.                                                                   |
| Classifier| Large predicted intent + dominant confidence bar + full 5-class distribution. Idle >5s → dimmed + "Classifier idle" banner.                                              |
| Journal   | Text input + voice recording (expo-audio). Past entries listed with timestamp, text, and audio playback. Local AsyncStorage only.                                       |

---

## Design decisions (deviations from the prompt)

1. **`react-native-chart-kit` not installed.** The prompt allows "or a custom SVG
   renderer." I went further: a **pure-RN polyline** rendered as 1.5px-wide
   absolutely-positioned `<View>` segments. Zero native deps, zero SDK-version
   drama (chart-kit v7.0.2 has a v1/v2 import-path split, peer-deps on
   `react-native-svg >=15.12.1 <16`, and known SVG performance issues at 30fps on
   1280 points). 640 segments per channel is well under React's reconciliation
   budget and renders smoothly on the Tensor G3.

2. **`expo-av` replaced with `expo-audio`.** `expo-av` was removed from the SDK 57
   bundle; the replacement is the new `expo-audio` package with hook-based API
   (`useAudioRecorder`, `useAudioPlayer`). The API in `DreamJournalScreen.tsx`
   reflects the new shape. See `SDK57-REFERENCE.md` for the full migration.

3. **`@react-native-async-storage/async-storage` pinned to 2.2.0** (the SDK 57
   bundled version). npm latest is 3.1.1 but it changed native wiring in v3; the
   2.2.0 pin keeps us on the tested path.

4. **Status bar text in `app.json` is `dark` mode by default** — the UI is dark.
   This is a UX choice; the prompt didn't specify.

5. **No `reconnecting-websocket` polyfill** — the package's README explicitly says
   it uses the global `WebSocket` and React Native 0.86 provides that natively.
   `LiveApiClient` does its own backoff (3 attempts, exp backoff capped at 30s)
   instead of depending on the npm package; if you want the package's reconnect
   behavior, swap it in.

---

## Tailscale cutover (when the M4 server is ready)

The M4 server is a separate PR — when it's up:

1. **Confirm Tailscale routing from Termux** (substitute your M4's Tailnet IP or
   MagicDNS name — never commit it):
   ```sh
   tailscale status              # should show the M4
   curl http://<m4-tailnet-host>:8081/api/diagnostics
   ```
   If the curl hangs, check `tailscale status` and `ip route` in Termux.

2. **Create `.env.local`** (gitignored — see `.env.example`):
   ```sh
   EXPO_PUBLIC_USE_MOCK=false
   EXPO_PUBLIC_SERVER_URL=http://<m4-tailnet-host>:8081
   # EXPO_PUBLIC_EEG_WS_URL is derived automatically (ws://…/api/eeg/stream)
   ```

3. **Reload the app** (or restart Metro). The top-right pill flips from `MOCK` to
   `LIVE` and the OverviewScreen pulls from the M4.

4. **Verify in order:**
   - Overview → live diagnostics, heartbeat < 1s ago
   - Health → 4 channels reporting, RMS values within ~10% of the macOS app
   - Classifier → predictions within 1s of cycling on the M4
   - EEG → traces scroll, the 4 channels match TP9/AF7/AF8/TP10
   - Pipeline mode → matches the macOS app's mode banner

5. **Cleartext traffic is already enabled on Android** in `app.json` via
   `expo-build-properties` with `usesCleartextTraffic: true`. Tailscale 100.x IPs
   are plain HTTP, and Android 9+ blocks plain HTTP by default — this flag
   unblocks it for the dev server. **iOS has no equivalent flag here on purpose:**
   App Transport Security blocks cleartext to non-localhost hosts, and this
   project does not add `NSAllowsArbitraryLoads`. For iOS hardware, serve HTTPS
   (e.g. `tailscale serve`) — see `docs/ios-client.md`. For production,
   terminate TLS in front of the M4 on both platforms.

---

## Build APK (EAS)

The user runs the EAS build — it requires `eas-cli` and an Expo account. The
30-builds/month free tier is enough for the v0.1 cycle.

```sh
npm install -g eas-cli
eas login
eas build:configure         # writes nothing new; this is a no-op once eas.json exists
eas build --platform android --profile preview
```

The `preview` profile produces a standalone APK (not a Play Store AAB). Download
from the EAS dashboard, install via `adb install` or just open the APK on the
Pixel.

For Play Store distribution later: `eas build --platform android --profile production`
emits an AAB.

---

## Verification done on this Pixel 8a

- `npx tsc --noEmit` — **0 errors** across 14 TS/TSX files
- `npx expo config --json --full` — config validates, all plugins resolve
- `npx expo export:embed --platform android` — **995 modules bundle in 14s**,
  4.6MB JS, no errors
- Hermes bytecode emission is **not** possible on a non-Android host — this is
  the expected Termux constraint; EAS handles it in the cloud build step

**Visual rendering in Expo Go is not testable from Termux** — you have to do that
manually on the device. The bundle is clean, the config is valid, the deps are
SDK-57-compatible.

---

## Known gotchas (mirrors Part 8 of the prompt)

- **RAM pressure.** If Metro + Expo Go OOMs, kill Metro (`Ctrl+C`), close Expo Go,
  restart Metro, reopen Expo Go. The Pixel 8a has 8GB but Android eats 2-3GB.
- **Termux process limits.** Use `termux-wake-lock` before long Metro sessions.
- **No `claude-mind-mcp` on Android** — memory bank unavailable; AsyncStorage is
  the only local persistence.
- **No local inference** — the cloud LLM is the only reasoning engine. The Pixel
  is renderer + storage only.
- **M4 server doesn't exist yet** — `USE_MOCK = true` is the default. When the M4
  HTTP server PR lands, flip the flag and reload.

---

## License

Same as the parent project (see `LICENSE`).
