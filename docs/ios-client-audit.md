# iOS Client Audit — baseline (pre-implementation)

Date: 2026-07-28
Auditor: Claude Code (M4 Mac, Terminal)
Worktree: `/Users/aurascoper/Developer/NeuralCompose-ios-client`
Branch: `feat/ios-client`, created from `origin/feat/dialect-synthesis` @ `2a2451fc4c1bb6856fc6640623f6959835fc8355`

> Note: the task prompt named the source branch `feat/dialectical-synthesis`. That
> ref does not exist on the remote. The operator confirmed `feat/dialect-synthesis`
> (the only branch containing the Expo client) as the intended source.

## MOBILE_IMPLEMENTATION_PRESENT=true

The branch root *is* the Expo project (`neuralcompose-client`). Real source,
real tests, real docs — not documentation-only. It was authored on a Pixel 8a
in Termux (jest config carries Android phantom-process workarounds; EAS was the
APK build path).

## Project facts

| # | Item | Finding |
|---|------|---------|
| 1 | Expo SDK | `expo ~57.0.8` (resolved `sdkVersion 57.0.0`) |
| 2 | React Native | `0.86.0` (React 19.2.3) |
| 3 | Node engines | none declared in `package.json`; `eas.json` pins Node `20.11.1` for EAS builds. Local Node v26.4.0 works. |
| 4 | Package manager | npm (`package-lock.json`, lockfileVersion 3). No other lockfiles. |
| 5 | Workflow | Managed / Continuous Native Generation. `/ios` and `/android` are gitignored ("generated native folders"). |
| 6 | `android/` committed | No |
| 7 | `ios/` committed | No |
| 8 | Native dirs hand-maintained | No — none exist; CNG intended. `expo prebuild` is safe here (still avoiding `--clean` per policy). |
| 9 | Expo Go support | All runtime deps are Expo-Go-bundled: expo-audio, expo-speech, expo-network, expo-status-bar, async-storage 2.2.0, react-navigation (bottom-tabs/native), safe-area-context, screens, react-native-svg, reconnecting-websocket (pure JS). |
| 10 | Deps requiring dev build | None at runtime. `expo-build-properties` is a config plugin (build-time only; inert in Expo Go). |
| 11 | Android-only deps | None in JS deps. Android-only *config*: `android.permissions: [RECORD_AUDIO]`, `usesCleartextTraffic: true` (Android block of expo-build-properties). |
| 12 | `expo-av` | **Not used.** |
| 13 | `expo-audio` | **Yes**, `~57.0.3` — recording + playback in `DreamJournalScreen` (`useAudioRecorder`, `useAudioPlayer`). Migration already done upstream. |
| 14 | Android package | `com.aurascoper.neuralcompose` (must remain unchanged) |
| 15 | iOS bundleIdentifier | Present at baseline: `com.aurascoper.neuralcompose`. No iOS build has ever used it (no credentials, no `ios/`). macOS app uses `com.neuralcompose.app` — no collision either way. |
| 16 | Endpoint config | Hard-coded compile-time constants in `src/config.ts`: `USE_MOCK = true`, `SERVER_URL`, `EEG_WS_URL`. On-device (Termux) services hard-coded: LLM `127.0.0.1:8081`, embeddings `:8082`, whisper.cpp STT `:8083`. No `EXPO_PUBLIC_*` usage anywhere. |
| 17 | Private Tailnet addresses committed | **Yes** — a `100.x` CGNAT address (the M4's Tailscale IP, commented "placeholder") in `src/config.ts` lines 6–7 and the README cutover section. Scrubbed in this branch; a hygiene test now guards against reintroduction. |
| 18 | Credentials / provider tokens | None found. No `.env*` files tracked. `scripts/termux/neuralcompose-services.env.example` is a server-side example without secrets. `.gitignore` covers `.env*.local`, keys, certs. |
| 19 | Baseline gate results | See below. |
| 20 | Android implementation real? | **Yes** — 6 screens, mock + live API clients, WS stream with throttled rendering, 13 Jest suites; `docs/fable5/verification-evidence.md` + `docs/pixel-benchmark-results.json` document on-device (Pixel 8a, Expo Go) verification by the prior effort. Not re-verified on Android hardware in this session. |

## Baseline gate results (exact commands, this machine)

| Gate | Command | Result |
|------|---------|--------|
| Install | `npm ci` | OK (warnings about install scripts for fsevents/unrs-resolver only) |
| Jest | `npm test -- --runInBand` | **PASS** — 11 suites passed, 2 skipped; 95 tests passed, 3 skipped. Warning: "Jest did not exit one second after the test run" (pre-existing open handle). |
| TypeScript | `npx tsc --noEmit` | **PASS** (exit 0) |
| Lint | `npm run lint --if-present` | No lint script defined — nothing ran. |
| expo-doctor | `npx expo-doctor` | **3 failures**: (a) app.json schema — `newArchEnabled` is no longer a valid key on SDK 57; (b) missing peer dependency `expo-asset` (required by `expo-audio`; "app may crash outside of Expo Go"); (c) jest 30.4.2 / @types/jest 30 vs SDK-expected ~29.7.0 / 29.5.14 (dev-only; suite is green on 30). |
| Public config | `npx expo config --type public` | Resolves; platforms `["ios","android"]` already. |
| Android export | `npx expo export --platform android` | **PASS** — Hermes bundle 2.1 MB. |
| iOS export | `npx expo export --platform ios` | **PASS** — Hermes bundle 2.1 MB. (JS bundling + static config evidence only.) |

## Architecture notes (thin-client conformance at baseline)

- `ApiClient` interface with `MockApiClient` / `LiveApiClient` selected **once** at
  module load from `USE_MOCK` — there is no runtime fallback path, so no silent
  live→mock substitution exists. Header badge shows `MOCK`/`LIVE` + endpoint.
- EEG: `useEEGStream` buffers outside React state, flushes at ~30 fps, caps the
  raw buffer at 2× `EEG_BUFFER_SAMPLES` (1280 = 5 s @ 256 Hz), cleans up socket +
  interval on unmount. `LiveApiClient` reconnects with exponential backoff capped
  at 3 attempts, drops malformed frames. Channel order TP9/AF7/AF8/TP10 fixed in
  fixtures and `HealthScreen`.
- Note: WS protocol is **one JSON sample per message** (~256 Hz), not batched.
  Display is throttled, so React state churn is bounded, but message decode runs
  per-sample.
- Journal: AsyncStorage stores metadata + text + audio **file URI** only; audio
  bytes live in the expo-audio recording file. Explicit mic permission request
  with a visible denied alert; text-only path preserved on denial.
- Locality labels are honest: `PrivacyBadge` renders the **server-reported**
  pipeline mode (FULLY LIVE / SUBSTITUTED); Dialectic screen labels `Gates: MOCK`
  and disables synthesis under mock embeddings. `runtime/identity.ts` verifies
  runtime identity by probing, defaulting to `unknown`.
- No `claude` CLI invocation, no Anthropic/OpenAI keys, no scientific EEG
  processing in JS. On-device LLM/STT/embedding clients target Termux-local
  `llama-server`/`whisper.cpp` loopback services (Android-only reality; on iOS
  these endpoints simply fail → visible "synthesis unavailable" / degraded
  states).

## Issues to address for universal iOS support

1. **`src/config.ts`**: committed Tailnet IP; compile-time `USE_MOCK`; no
   `EXPO_PUBLIC_*` env plumbing; no `.env.example`.
2. **app.json**: invalid `newArchEnabled` key; no `scheme`; no iOS
   `NSMicrophoneUsageDescription` despite recording; no `ios.buildNumber` /
   `android.versionCode`; bundle ID to be set to the preferred
   `com.aurascoper.neuralcomposeclient` (safe — never used by any build).
3. **Missing `expo-asset` peer dep** (expo-doctor failure; dev-build crash risk).
4. **jest 30 vs SDK expectation** — keep 30 (green), silence via
   `expo.install.exclude` with rationale.
5. **iOS ATS vs `http://` endpoints**: Android uses `usesCleartextTraffic`; on
   iOS, cleartext to non-loopback hosts is blocked by ATS. Policy: do **not**
   add `NSAllowsArbitraryLoads` or broad exemptions. Simulator→`http://localhost`
   is ATS-exempt; physical iPhone needs HTTPS (e.g. `tailscale serve`) — document.
6. **eas.json**: no `development` profile (`developmentClient`); add without
   touching working Android profiles.
7. iOS Local Network: LAN endpoints on a dev/EAS build need
   `NSLocalNetworkUsageDescription` (Expo Go carries its own).

## Phase 3 decision

```
IOS_DEVELOPMENT_PATH=expo-go
```

Evidence: every runtime native module (expo-audio, expo-speech, expo-network,
expo-status-bar, async-storage, react-native-svg, screens, safe-area-context) is
bundled in Expo Go for SDK 57; no custom native code, no custom entitlements, no
unsupported packages. `expo-build-properties` only affects generated native
builds and is inert in Expo Go. A development build is *not* required for the
current feature set; EAS profiles are kept for distribution builds.
