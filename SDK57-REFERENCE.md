# Expo SDK 57.0.8 — Package Compatibility Reference

**Project:** `~/neuralcompose-client` · React Native 0.86 · React 19.2 · Android (Pixel 8a)
**SDK release date:** June 30, 2026 · [Official changelog](https://expo.dev/changelog/sdk-57)
**Manifest source of truth:** `https://raw.githubusercontent.com/expo/expo/sdk-57/packages/expo/bundledNativeModules.json`
**All version numbers below were pulled from the SDK 57 bundledNativeModules.json (the manifest Expo uses for `npx expo install --fix`).**

---

## 1. react-native-svg

- **Recommended version:** **`15.15.4`** (pinned in SDK 57 manifest) — `15.15.5` is the latest on npm and is also fine (same major.minor).
- **SDK 57 compat notes:** No known version conflict. `expo-svg` is the wrapper that re-exports `react-native-svg`; you can use either import. Works with **New Architecture** (default in SDK 57).
- **react-native-chart-kit constraint:** peer-dep `react-native-svg >=15.12.1 <16` — both 15.15.4 and 15.15.5 satisfy this.
- **Source:** [docs.expo.dev/versions/v57.0.0/sdk/svg](https://docs.expo.dev/versions/v57.0.0/sdk/svg/) · npm: `registry.npmjs.org/react-native-svg` (15.15.5)

## 2. expo-av (REMOVED from SDK 57)

- **Status:** `expo-av@16.0.8` is the **last** published version on npm (released Oct 2025). It is **NOT** in the SDK 57 `bundledNativeModules.json` and the doc URL `https://docs.expo.dev/versions/v57.0.0/sdk/av/` returns **404**.
- **Replacement in SDK 57:**
  - `expo-audio@~57.0.3` — recording + playback (https://docs.expo.dev/versions/v57.0.0/sdk/audio/)
  - `expo-video@~57.0.2` — video playback (https://docs.expo.dev/versions/v57.0.0/sdk/video/)
- **API shape (new):**
  - Recording: `useAudioRecorder(RecordingPresets.HIGH_QUALITY)` + `AudioModule.setAudioModeAsync(...)` + `recorder.record()` / `recorder.stop()` / `recorder.uri`
  - Playback: `useAudioPlayer(source)` or `createAudioPlayer(source)` (NOT `Audio.Sound`).
- **Migration path for `expo-av` → `expo-audio` + `expo-video`:** see each library's "API Definition" + example on its SDK 57 page. Heads up: `Audio.Recording` is gone; use `useAudioRecorder` hook (hook form, not class).
- **Source:** [changelog SDK 57](https://expo.dev/changelog/sdk-57) · [expo-audio docs](https://docs.expo.dev/versions/v57.0.0/sdk/audio/) · [expo-video docs](https://docs.expo.dev/versions/v57.0.0/sdk/video/)

## 3. @react-native-async-storage/async-storage

- **Recommended version for SDK 57:** **`2.2.0`** (this is what `bundledNativeModules.json` pins and what `npx expo install --fix` will give you). Stays compatible with `react-native@0.86.0` per peer-dep `^0.0.0-0 || >=0.65 <1.0`.
- **Latest on npm:** **`3.1.1`** — peer-dep is `react-native: *` (works with 0.86), but **v3.0.0 was deprecated** for a "critical bug" (use 3.0.1+).
- **Breaking changes v2 → v3:** minor; v3 changed the native module wiring. Sticking with the **SDK-bundled 2.2.0** is the safer choice for this project and will be selected automatically by `expo install --fix`.
- **Source:** [SDK 57 async-storage docs](https://docs.expo.dev/versions/v57.0.0/sdk/async-storage/) · npm: `registry.npmjs.org/@react-native-async-storage/async-storage`

## 4. @react-navigation/bottom-tabs (v7)

- **Recommended version:** **`@react-navigation/bottom-tabs@7.18.13`** (latest on npm). Pair with `@react-navigation/native@7.3.13`.
- **Required peer dependencies (still required, unchanged from v6):**
  - `react-native-screens` — `~4.26.0` (npm latest 4.26.2) · peer-dep `react-native-screens >= 4.0.0`
  - `react-native-safe-area-context` — `~5.7.0` (npm latest 5.8.0) · peer-dep `react-native-safe-area-context >= 4.0.0`
  - `react` `>= 18.2.0` (you have 19.2 — fine)
- **SDK 57 compat notes:** No v7 → v8 pressure; v7 is the current stable line per `reactnavigation.org` and the page version selector is on 7.x. No breaking changes since 7.0; install is `npm install @react-navigation/bottom-tabs` and React Navigation's getting-started guide explicitly says: *"`expo install` will install versions of these libraries that are compatible with your Expo SDK version"*.
- **Source:** [reactnavigation.org/docs/bottom-tab-navigator](https://reactnavigation.org/docs/bottom-tab-navigator) · [reactnavigation.org/docs/getting-started](https://reactnavigation.org/docs/getting-started) · npm peer-deps

## 5. react-native-chart-kit

- **Recommended version:** **`7.0.2`** — released **2026-07-09** (≈ 2 weeks before this session). **Actively maintained.**
- **SDK 57 compat notes:** New peer-deps explicitly written for SDK 57 / RN 0.86:
  - `react: >=19.1.0 <20` (you have 19.2 ✓)
  - `react-native: >=0.81 <1` (0.86 ✓)
  - `react-native-svg: >=15.12.1 <16` (15.15.4 ✓)
- **IMPORTANT import path change:** the v2 API is now on a subpath. New code MUST import from **`react-native-chart-kit/v2`**, not the root:
  - `import { LineChart } from "react-native-chart-kit/v2";` ← correct
  - `import { LineChart } from "react-native-chart-kit";` ← legacy v1 wrapper, partial-compat only
- **1280-point / 30 fps performance:** **Built-in decimation** handles this. From the official LineChart docs: *"LineChart uses automatic path-only min/max decimation by default."* You can override:
  - `decimation="auto"` (default) — min/max simplification
  - `decimation={{ maxPoints: 700 }}` — cap rendered path complexity
  - For scrollable viewports: `scrollable visiblePoints={30} initialIndex="end"` — renders only 30 points in the viewport window, regardless of total series size. This is exactly the pattern for streaming 1280 samples at 30 fps.
- **No known SDK 57 regressions** — peer-deps were published with SDK 57 in mind.
- **Source:** [chartkit.io/docs/react-native/charts/line](https://chartkit.io/docs/react-native/charts/line/) (Decimation section) · [migration/from-v1](https://chartkit.io/docs/react-native/migration/from-v1/) · npm release timestamps

## 6. expo-network

- **Recommended version:** **`~57.0.1`** (pinned in SDK 57 manifest; npm latest 57.0.1).
- **SDK 57 compat notes:** No breaking changes vs SDK 56. API includes `getNetworkStateAsync()`, `isAirplaneModeEnabledAsync()` (Android), `getIpAddressAsync()` — useful for detecting Tailscale interface IPs.
- **Source:** [docs.expo.dev/versions/v57.0.0/sdk/network](https://docs.expo.dev/versions/v57.0.0/sdk/network/)

## 7. reconnecting-websocket

- **Recommended version:** **`4.4.0`** (npm latest; no peer-deps).
- **Polyfill needed?** **No.** The library's README explicitly states it is "Multi-platform (Web, ServiceWorkers, Node.js, **React Native**)" and uses the global `WebSocket` constructor — which React Native 0.86 provides natively (in the new `WebSocketModule` that ships with RN core).
- **Known issues:** None documented. No SDK 57-specific regressions. The library is "dependency free" and "WebSocket API compatible", so it works against any RN version that has a working `WebSocket` global.
- **Source:** [github.com/pladaria/reconnecting-websocket README](https://github.com/pladaria/reconnecting-websocket) · npm: `registry.npmjs.org/reconnecting-websocket` (4.4.0)

## 8. Tailscale on Android + RN 0.86 + cleartext traffic for `http://100.x.y.z`

**Direct, citable answers:**

- **Tailscale 100.x "MagicDNS" IPs are normal CGNAT-style private IPs.** Android routes them through the Tailscale VPN interface; no special RN config is needed for the OS-level routing. React Native's `fetch` and `WebSocket` go through the same OkHttp socket layer that the rest of the OS uses, so VPN-routed traffic works out-of-the-box on Android 9+.
- **HOWEVER: cleartext traffic (plain `http://`, no TLS) is BLOCKED by default on Android 9+.** Both the [React Native Networking docs](https://reactnative.dev/docs/network) and the [Expo build-properties docs](https://docs.expo.dev/versions/v57.0.0/sdk/build-properties/) confirm this. Quoting the Expo build-properties page verbatim:
  > `usesCleartextTraffic` (optional) `boolean` — Indicates whether the app intends to use cleartext network traffic. **For Android 8 and below, the default platform-specific value is `true`. For Android 9 and above, the default platform-specific value is `false`.**
- **Therefore for `http://100.x.y.z:8081` on a Pixel 8a (Android 16, which is >9):** **YES, you must enable cleartext.** The cleanest way in SDK 57 is the `expo-build-properties` config plugin (this is the *only* mechanism — the old `expo.http` app.json key was removed in SDK 53):

  ```json
  // app.json
  {
    "expo": {
      "plugins": [
        ["expo-build-properties", {
          "android": {
            "usesCleartextTraffic": true
          }
        }]
      ]
    }
  }
  ```

  Then run `npx expo prebuild --clean` (or `npx expo run:android` which triggers prebuild). The plugin writes `android:usesCleartextTraffic="true"` into the generated `AndroidManifest.xml`.
- **Better alternative for production:** put a TLS terminator (Caddy/nginx) in front of your dev server and use `https://100.x.y.z:8443`. Then you don't need cleartext and you avoid the warning. For pure local dev on Tailscale, the cleartext flag is fine.
- **Tailscale-specific gotcha (not in Expo docs, well-known):** Tailscale's `MagicDNS` resolves node names like `my-devbox.tailnet.ts.net` → `100.x` IP. Android's WebView (and some libraries' HttpURLConnection) resolves DNS through the VPN, so this works — but if you ever see "ERR_CLEARTEXT_NOT_PERMITTED" in logcat, that's the manifest flag missing, **not** a Tailscale problem.
- **Source:** [Expo build-properties `usesCleartextTraffic`](https://docs.expo.dev/versions/v57.0.0/sdk/build-properties/) · [React Native Networking](https://reactnative.dev/docs/network)

---

## TL;DR install command

```bash
cd ~/neuralcompose-client
npx expo install --fix      # pins everything to the SDK 57 manifest
npx install-local-packages  # then add chart-kit + reconnecting-websocket which aren't in the manifest
```

Manual `package.json` versions that will pass `expo doctor` and `npx expo install`:

```json
{
  "dependencies": {
    "expo": "~57.0.8",
    "react": "19.2.0",
    "react-native": "0.86.0",
    "react-native-svg": "15.15.4",
    "expo-audio": "~57.0.3",
    "expo-video": "~57.0.2",
    "expo-network": "~57.0.1",
    "expo-build-properties": "~57.0.7",
    "@react-native-async-storage/async-storage": "2.2.0",
    "@react-navigation/native": "^7.3.13",
    "@react-navigation/bottom-tabs": "^7.18.13",
    "react-native-screens": "~4.26.0",
    "react-native-safe-area-context": "~5.7.0",
    "react-native-chart-kit": "^7.0.2",
    "reconnecting-websocket": "^4.4.0"
  }
}
```

⚠️ **Do NOT install `expo-av`.** It is not bundled in SDK 57. Use `expo-audio` instead.

---

## Source URL index (all cited above)

- Expo SDK 57 changelog: https://expo.dev/changelog/sdk-57
- SDK 57 bundledNativeModules manifest: https://github.com/expo/expo/blob/sdk-57/packages/expo/bundledNativeModules.json
- expo-audio: https://docs.expo.dev/versions/v57.0.0/sdk/audio/
- expo-video: https://docs.expo.dev/versions/v57.0.0/sdk/video/
- react-native-svg: https://docs.expo.dev/versions/v57.0.0/sdk/svg/
- async-storage: https://docs.expo.dev/versions/v57.0.0/sdk/async-storage/
- expo-network: https://docs.expo.dev/versions/v57.0.0/sdk/network/
- expo-build-properties: https://docs.expo.dev/versions/v57.0.0/sdk/build-properties/
- @react-navigation/bottom-tabs: https://reactnavigation.org/docs/bottom-tab-navigator
- @react-navigation getting-started: https://reactnavigation.org/docs/getting-started
- chart-kit v2 line chart (decimation): https://chartkit.io/docs/react-native/charts/line/
- chart-kit v1 → v2 migration: https://chartkit.io/docs/react-native/migration/from-v1/
- reconnecting-websocket: https://github.com/pladaria/reconnecting-websocket
- React Native cleartext statement: https://reactnative.dev/docs/network
- npm registry: https://registry.npmjs.org/<package-name>/latest
