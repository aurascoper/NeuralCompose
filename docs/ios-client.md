# NeuralCompose Universal Client — iOS

Universal Android/iOS Expo thin client for the macOS NeuralCompose BCI pipeline.
Baseline audit: `docs/ios-client-audit.md`.

## Thin-client architecture and privacy boundary

The **M4 Mac is authoritative** for everything scientific: Muse/EEG acquisition,
preprocessing, channel health, classification, Core ML, MLX, LLM execution,
dialectical competition, Witness processing, provenance, raw artifacts,
recording and replay.

The phone only does: screen rendering, API/WebSocket consumption, bounded
display buffering, local caching, local journal text, local audio
recording/playback, platform TTS, and connection/locality/staleness
presentation.

The mobile waveform is a **monitoring visualization**, not a scientific source
artifact. The phone never decodes cognition or brain state. The `claude` CLI is
never invoked from the phone. No provider secrets exist in client source —
`EXPO_PUBLIC_*` values are **public** (inlined into the JS bundle).

Locality labels distinguish:

- **phone-local** — rendering, cache, journal, audio recording
- **Mac-local** — EEG acquisition/processing, classification, Core ML, MLX
- **remote cloud** — only when the Mac's pipeline mode explicitly reports it

The UI never claims `On-device` for work the M4 performs; the Overview banner
renders the **server-reported** pipeline mode verbatim.

## Paths

- Repository: `https://github.com/aurascoper/NeuralCompose.git`
- Mobile project: repository root of the `feat/ios-client` /
  `feat/dialect-synthesis` branch lineage (the branch tree *is* the Expo app)
- Expo SDK 57 / React Native 0.86 / npm / managed workflow (CNG; `ios/` and
  `android/` are generated, gitignored, never hand-maintained)

## Identifiers

- Android package (unchanged): `com.aurascoper.neuralcompose`
- iOS bundle identifier: `com.aurascoper.neuralcomposeclient`
- URL scheme: `neuralcompose`
- macOS app (separate product): `com.neuralcompose.app`

## Environment variables

Copy `.env.example` → `.env.local` (gitignored). All are `EXPO_PUBLIC_*` and
therefore **public — never place secrets or permanent private Tailnet addresses
in them or in committed source** (a Jest hygiene test enforces the latter).

| Var | Meaning |
|-----|---------|
| `EXPO_PUBLIC_USE_MOCK` | `true` (default when unset) = mock fixtures, labeled `MOCK`; `false` = live. No silent live→mock fallback exists: live failures surface as error/stale states, and a live config without a server URL shows `LIVE · NO ENDPOINT`. |
| `EXPO_PUBLIC_SERVER_URL` | The M4 server, e.g. `https://<mac>.<tailnet>.ts.net:8081` |
| `EXPO_PUBLIC_EEG_WS_URL` | Optional; derived from the server URL (`ws(s)://…/api/eeg/stream`) when empty |
| `EXPO_PUBLIC_LLM_URL` / `EXPO_PUBLIC_EMBEDDING_URL` / `EXPO_PUBLIC_STT_URL` | Optional overrides for the loopback services that exist only on the Termux/Android deployment; unset on iOS → features degrade visibly |

## macOS prerequisites

- Xcode (full app, not just CLT); verify with `xcode-select -p` /
  `xcodebuild -version`
- iOS **Simulator runtime** — Xcode 26 ships it separately:
  `xcodebuild -downloadPlatform iOS` (multi-GB, one-time), then
  `xcrun simctl list devices available`
- Node ≥ 20, npm; install with `npm ci`

## Workflows

### Android (Expo Go) — regression path

```sh
npm ci
npx expo start --clear     # scan QR from Expo Go on the device
```

Regression gates before any commit:

```sh
npm test -- --runInBand
npx tsc --noEmit
npx expo-doctor
npx expo export --platform android
```

### iOS (Expo Go) — chosen development path

`IOS_DEVELOPMENT_PATH=expo-go`. Every native dependency (expo-audio,
expo-speech, expo-network, expo-status-bar, async-storage, react-native-svg,
screens, safe-area-context, expo-asset) is bundled in Expo Go for SDK 57; there
is no custom native code and no custom entitlement. `expo-build-properties`
only affects generated native builds and is inert in Expo Go.

```sh
npx expo start --clear     # press i for the iOS Simulator (installs Expo Go there)
```

### Local iOS development build (when native needs appear)

Not required today. When it becomes necessary:

```sh
npx expo install expo-dev-client
npx expo prebuild --platform ios   # CNG project — safe; never use --clean by habit
npx expo run:ios                    # compiles natively, installs to Simulator
```

### EAS builds (cloud)

Requires `eas` authentication (`npx eas-cli@latest whoami`) and, for device
builds, Apple Developer membership + signing. Profiles in `eas.json`:

- `development` — `developmentClient: true`, internal distribution
- `development-simulator` — the same, built for the iOS Simulator (no signing)
- `preview` / `preview-simulator` — internal distribution (Android profile
  predates this work and is untouched)
- `production` — auto-increment, Android app-bundle

```sh
npx eas-cli@latest build --platform ios --profile development-simulator
```

Do not print or commit Apple credentials, tokens, certificates, or
provisioning profiles.

### Physical iPhone

Optional; needs a connected iPhone (`xcrun xctrace list devices`), Apple
signing, and operator participation for credentials. Then
`npx expo run:ios --device` or an EAS `development` build. Networking: a
physical iPhone cannot reach the Mac via `localhost` — see transport below.

## Transport security (HTTPS / LAN / Tailnet)

- Android cleartext HTTP is enabled (`usesCleartextTraffic`, Android-only,
  pre-existing).
- iOS **App Transport Security is left fully intact**: no
  `NSAllowsArbitraryLoads`, no exception domains. Consequences:
  - iOS **Simulator** → `http://localhost:8081` works (loopback is ATS-exempt)
    when the server runs on the same Mac.
  - **Physical iPhone** → use HTTPS, e.g. `tailscale serve` in front of the M4
    server, or a LAN reverse proxy with a trusted cert. Plain `http://100.x…`
    or `http://192.168…` will be blocked by ATS — this is intentional; do not
    "fix" it by disabling ATS.
- `NSLocalNetworkUsageDescription` is declared because the live endpoint is
  user-owned LAN/Tailnet equipment; iOS shows the Local Network prompt for LAN
  access from a native build (Expo Go carries its own).

## Microphone, speech, audio storage

- Recording uses `expo-audio` (already migrated off `expo-av` upstream; nothing
  to migrate). Explicit permission request on the Journal screen; denial shows
  a visible alert and text entry keeps working.
- `NSMicrophoneUsageDescription` is declared for iOS; `RECORD_AUDIO` for
  Android (pre-existing).
- Audio bytes live in device **file storage** (expo-audio recording URI);
  AsyncStorage holds only metadata (timestamp, journal text, audio file URI,
  duration). Local-only; no upload.
- **Speech-to-text status:** the app does not implement application-controlled
  STT on iOS. The Termux deployment can point `EXPO_PUBLIC_STT_URL` at a local
  whisper.cpp server; without it, transcription degrades visibly. The system
  keyboard's dictation remains a user-controlled option. A native
  Apple-Speech bridge would be a separately justified, tested track.
- Spoken output uses `expo-speech` (platform TTS) on both platforms.

## Evidence ledger (2026-07-28 session, M4 Mac)

Never collapse these into "iOS works":

| Evidence class | Status |
|----------------|--------|
| Jest + TypeScript | **Observed green** — 15 suites / 184 tests passed (2 suites, 3 tests skipped); `tsc --noEmit` clean; `expo-doctor` 20/20 |
| Android JS bundle | **Observed green** — `npx expo export --platform android` (Hermes, 2.1 MB) |
| Android Expo Go / device | **Not observed this session** — prior effort's Pixel 8a evidence in `docs/fable5/verification-evidence.md`; re-run the regression path above |
| Static iOS export | **Observed green** — `npx expo export --platform ios` (JS bundling + static config only; proves nothing about native compilation, signing, audio, or devices) |
| Native iOS compilation | **Not observed** — Expo Go path chosen; no prebuild run |
| iOS Simulator (Expo Go) | **Observed** — iPhone 17, iOS 26.5 (runtime installed via `xcodebuild -downloadPlatform iOS`): Expo Go installed by the CLI; bundle `iOS Bundled … (1029 modules)`; app launched; all six tabs rendered and navigated (Overview with green `MOCK DATA` pill + live-updating mock diagnostics, EEG 4 traces in TP9/AF7/AF8/TP10 order at "~30 fps render", Health fixture states incl. AF8 SATURATED, Classifier intent + distribution, Dialectic idle with "Gates: MOCK … Synthesis is disabled", Journal entry UI); iOS microphone permission prompt appeared on Journal (Expo Go's own usage string — the app's `NSMicrophoneUsageDescription` applies to dev/EAS builds); fast refresh applied a code change live. **Not observed on Simulator:** in-app mic-denied alert state, recording start/stop, stale-stream state, background/foreground cycling. |
| Physical iPhone | **Not observed** — no signing configured this session |
| EAS cloud build | **Not run** — `eas whoami`: not logged in; profiles configured |

## Known limitations

- Dialectic tab's loopback LLM/embedding/STT services are an Android/Termux
  deployment reality; on iOS they are absent and the screen shows its degraded,
  labeled states (`Gates: MOCK`, synthesis disabled) unless overrides point at
  reachable hosts.
- Jest emits a benign pre-existing "did not exit one second after the test
  run" warning (open handle in a mock timer).
- `jest`/`@types/jest` are pinned at v30 (SDK expects 29; suite is green on
  30) and excluded from `expo install --check` via `expo.install.exclude`.
- No splash-screen config is declared; both platforms use Expo defaults with
  the existing icon set.
