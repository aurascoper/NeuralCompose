# NeuralCompose — Live OSC/EEG Ingestion Review (2026-07-20)

Retrospective, multi-lens review of the **live EEG over Mind Monitor OSC/UDP** path — the app's first inbound-network runtime surface, landed 2026-07-20 and already merged to `main`. Three adversarial lenses (Swift-6 correctness/concurrency, silent-failure/diagnostics, network security) over the scoped diff only; **read-only, no code changed**. Scope: `Sources/BCIEEG/OSC/*`, `EEGStreamFactory`, the demean-fix sites, the `.oscRemote` gating/banner, `Info.plist`, `Scripts/sign-app-local.sh`. Findings were deduped across lenses and each was verified against the current source (the two Critical items were re-read by hand).

## Verdict

The OSC path is well-built where it counts: the `@unchecked Sendable` + `NSLock` concurrency model is **correctly implemented** (every mutable field is lock-guarded; `continuation.yield` is correctly called outside the lock), and the OSC byte parser is **bounds-safe** (no over-read, no zero-size loop, no integer-overflow on the size cast — all explicitly checked and refuted). The problems are two self-contained **blocking** defects and a cluster of **honest-signal-health** gaps that compound into one bad failure mode.

The single highest-leverage issue: the stall watchdog keys off **raw packet arrival, not EEG-sample throughput**, so motion/telemetry traffic keeps the link "green" while EEG is silently dead — the transport-layer reprise of the "overnight-review still false-green / no zero-throughput watchdog" gap. Fixing **C1** also unblocks **H1** and **M2**. The other blocking item, **C2**, is a crafted-packet DoS crash with a small, obvious fix.

**Fix C1 and C2 first — both are small, and they are the two ways this path can silently fake a session or be crashed on demand.**

---

## Punch list (plan-ready gate)

| ID | Sev | One-line | Fix locus |
|----|-----|----------|-----------|
| C1 | Blocking | Watchdog keys off packet arrival, not EEG throughput → unbounded false-green | `MindMonitorOSCStream.swift:246` |
| C2 | Blocking | Unbounded bundle recursion → remote stack-exhaustion crash | `MuseOSCDecoder.swift:106` |
| H1 | Should-fix | Top-line `signalQuality` has no staleness gate → stale "Signal OK" | `AppViewModel.swift:564,664` |
| H2 | Should-fix | `packetsDropped` counts routine non-EEG msgs as loss; counters mix units | `MindMonitorOSCStream.swift:268` |
| M1 | Should-fix | `NWConnection` never cancelled → UDP-socket leak on the stale path | `MindMonitorOSCStream.swift:142-234` |
| M2 | Should-fix | Receive-loop connection error is log-only, never `finish(throwing:)` | `MindMonitorOSCStream.swift:222-228` |
| M3 | Should-fix | OSC→synthetic degrade keeps the same "Standby"/orange banner → real→fake easy to miss | `PrivacyIndicatorView.swift:292-303` |
| M4 | Should-fix | `0.0.0.0` bind + no source filter/auth → LAN-reachable crash + EEG injection | `MindMonitorOSCStream.swift:87` |
| M5 | Should-fix | App not sandboxed → no-network invariant is convention, not OS-enforced; `CLAUDE.md` drift | (entitlements) + `CLAUDE.md:3` |
| M6 | Should-fix | `sign-app-local.sh` imports key `-A` + installs self-signed trust root | `Scripts/sign-app-local.sh:56,59` |
| M7 | Should-fix | Demean can push a floating electrode into the "healthy" RMS band | `AppViewModel.swift:1439`; `EEGChannelHealthProvider.swift:209` |
| L1 | Nice | `computeCalibrationMetrics` skipped by the demean fix (raw RMS + `NaN` on empty) | `AppViewModel.swift:1408-1415` |
| L2 | Nice | ≥2 connections → non-monotonic timestamps + meaningless jitter | `MindMonitorOSCStream.swift:102-109,257` |
| L3 | Nice | `codesign --deep` for *signing* (deprecated; mis-signs nested code) | `sign-app-local.sh:69`; `package-app-bundle.sh:105` |
| L4 | Nice | Hardcoded transient p12 password (ephemeral; informational) | `sign-app-local.sh:28` |
| L5 | Nice | `start()` TOCTOU, dead `?? 5000`, wall-clock vs monotonic heartbeat | `MindMonitorOSCStream.swift` |

Cross-cutting: **C1 + H1 + M2** compound — if EEG stops while the headband keeps sending motion/telemetry, the user sees a frozen green "Signal OK", a "Standby" (not degraded) banner, a `packetsDropped` that *looks* like loss but is normal, and no retry/degrade. The only correct signal (`EEGChannelHealthProvider`'s 2s `.stale`) is confined to `SleepValidationView` and never reaches the main banner.

---

## CRITICAL (blocking)

### C1 — Stall watchdog is a packet watchdog, not an EEG-sample watchdog
`Sources/BCIEEG/OSC/MindMonitorOSCStream.swift:246` (heartbeat), `:128-129`/`:209-214` (watchdog reads it), `:265` (the sample counter it *should* use)

`handlePacket` sets `lastHeartbeat = Date()` on **every inbound datagram**, unconditionally, at `:246` — before decode (`:262`) and regardless of whether the datagram yields an EEG sample. The 1 Hz watchdog measures staleness against `lastHeartbeat`. Mind Monitor emits `/muse/acc`, `/muse/gyro`, `/muse/batt`, `/muse/elements` continuously while the headband is powered/paired, independent of scalp contact. So if the `/muse/eeg` substream specifically stops (electrodes lift, EEG toggled off, NaN'd channels) while motion keeps flowing, `lastHeartbeat` keeps refreshing → the watchdog **never fires** → the supervisor never throws, never retries, never degrades. `samplesYielded` is frozen at the last value and nothing surfaces. Even a sender blasting malformed UDP keeps the link "alive" (`:246` precedes the decode that would reject it). The Q4 "~5 s stale window" is the *best* case (all traffic stops); with telemetry present the false-green window is **unbounded**.

**Fix:** drive the watchdog off EEG throughput — track a `lastSampleYieldedWallClock` updated only where `samplesYielded += 1` (`:265`) and require it to advance within the timeout. Keep the raw-arrival timeout as a secondary "link totally dead" signal if desired.

### C2 — Unbounded recursion in the bundle decoder → remote DoS crash (CWE-674)
`Sources/BCIEEG/OSC/MuseOSCDecoder.swift:88-113` (self-call `:106`); reachable from `MindMonitorOSCStream.swift:262` → `handlePacket`, parsing on a `.global(qos:.userInitiated)` worker thread

`decodeBundleElements` recurses whenever an element is itself a `#bundle` (`:105-106`) with no depth counter and no ceiling. Each nesting level costs only ~20 bytes (`4` size prefix + `16` `#bundle\0` + timetag), so a single UDP datagram (~65,507-byte IPv4 cap) encodes **~3,200+ recursion levels**. The receive callback parses on a libdispatch global-queue worker whose stack (~512 KB) is far smaller than main's 8 MB; a few thousand frames overrun it → `EXC_BAD_ACCESS`, which Swift **cannot** catch (the `do/catch` at `MindMonitorOSCStream.swift:271` only catches thrown `Error`, not a stack fault) → **the whole app crashes mid-session** for an accessibility user who communicates through it. The `:98` size guard bounds *over-read*, not *depth*; the 64 KB cap bounds the packet, not the depth it encodes. Existing tests exercise nesting only to depth 2.

**Fix:** add a `depth` parameter and `throw` past a small cap (OSC nesting >2–3 has no legitimate Mind Monitor use — cap at ~8); add a regression test feeding a deeply-nested bundle that asserts a thrown error, not a crash. Optionally cap total decoded messages per packet.

---

## HIGH

### H1 — Published `signalQuality` has no staleness gate
`Sources/NeuralComposeApp/AppViewModel.swift:564` (set per new window), `:664` (set `.lost` only *after* the stream throws)

The `signalQuality` the always-visible `PrivacyIndicatorView.signalBadge` renders is written in exactly two places: per-window at `:564`, and `.lost` in the retry branch at `:664` — which is only reached *after* the (C1-defeatable) watchdog throws. Between packets stopping and the watchdog firing, `signalQuality` holds its last value; if `.healthy`, the banner shows green "Signal OK" over dead data. A 2 s staleness mechanism exists (`EEGChannelHealthProvider` `.stale`, `:125-134`) but is wired only into `SleepValidationView`, so the two readouts diverge. Best case ~5 s; with C1, indefinite.

**Fix:** gate the published `signalQuality` on wall-clock-since-last-window (mirror the provider's `secondsSinceLastIngest`), or source the banner badge from the stale-aware provider so the prominent indicator can't outrun reality.

### H2 — `packetsDropped` counts legitimate non-EEG messages as drops; counters mix units
`Sources/BCIEEG/OSC/MindMonitorOSCStream.swift:268` (+ `:273`, `:245`, `:265`); `MindMonitorDecoder.swift:10-13`

Every message whose address isn't `/muse/eeg` returns `nil` and hits `packetsDropped += 1` (`:268`) — so every `/muse/acc|gyro|batt|elements` on a *healthy* link inflates a "packet loss" metric at tens of Hz, and genuine corruption (`:273`) is buried in the same counter. The decoder's own contract (`MindMonitorDecoder.swift:10-13`) calls these "silently ignored — not an error." Compounding: `packetsReceived` counts *datagrams* (`:245`) while `samplesYielded`/`packetsDropped` count *messages* inside bundles (`:265`/`:268`), so `dropped/received` is a nonsense ratio.

**Fix:** split into `ignoredNonEEG` (nil for a known non-EEG address), `droppedShortEEG` (`/muse/eeg` with <4 floats, `MindMonitorDecoder.swift:47`), and `droppedMalformed` (decode threw). Only the latter two belong in a loss metric.

---

## MEDIUM (should-fix)

### M1 — `NWConnection` never cancelled → UDP-socket leak on the stale-link path
`Sources/BCIEEG/OSC/MindMonitorOSCStream.swift:142-145,149-151,218-234`

The class never stores accepted `NWConnection`s; `stop()` and `onTermination` cancel only the *listener*, which does **not** tear down already-accepted connections. When the watchdog fires because the phone went silent, the connection's armed `receiveMessage` completion retains the connection (and its live UDP socket) for the process lifetime — and because no packet ever arrives again, the cleanup path never runs. The watchdog and the leak collide in exactly the same scenario.

**Fix:** track connections (append in `newConnectionHandler`, lock-protected), cancel them all in both `stop()` and `onTermination`, and drop each when its receive loop ends.

### M2 — Receive-loop connection error is log-only; recovery hinges on the (C1-defeatable) watchdog
`Sources/BCIEEG/OSC/MindMonitorOSCStream.swift:222-228`

On a `receiveMessage` error the loop logs `.error`, `cancel()`s the connection, and returns — it never `continuation.finish(throwing:)`, so the error reaches neither the supervisor's `catch` nor `lastError`. Recovery depends entirely on the stall watchdog, which C1 shows can be held open indefinitely by non-EEG traffic. The error detail is dropped.

**Fix:** on connection error, `finish(throwing: BCIError.streamFailed(...))` with the underlying error, or record it into `StreamDiagnostics` (`lastConnectionError`), so surfacing/recovery isn't solely watchdog-dependent.

### M3 — OSC→synthetic degrade keeps the same banner title/color; real→fake is easy to miss
`Sources/NeuralComposeApp/PrivacyIndicatorView.swift:292-303`; degrade at `AppViewModel.swift:650-652,498,1462-1476`

The strong form of the concern is **refuted**: `publishMode` *does* flip the caption from "EEG: OSC Remote (network)" to "EEG: Synthetic" before any synthetic sample flows, so there's no window of unpublished fake data. The real weakness: both `remotePhone` and `synthetic` are `isFullyLive == false` (`PipelineMode.swift:104-106`), so `statusTitle` stays "Standby pipeline" and `statusColor` stays `.orange` across the whole transition. The only deltas are the caption text and the green badge *disappearing*. A user not reading the caption sees the same orange "Standby" before and after switching from real remote EEG to fabricated data. Minor: `isReconnecting` is cleared (`:652`) one MainActor hop before the synthetic mode is published (`:498`) — publish the new mode first, then clear the flag.

**Fix:** give the synthetic-fallback state an unmistakable visual (distinct color or a "Simulated data" pill); amber "Standby" already *is* the OSC-live look.

### M4 — UDP listener binds all interfaces with no auth → LAN-reachable crash + EEG injection (CWE-1327/306)
`Sources/BCIEEG/OSC/MindMonitorOSCStream.swift:87`; no source check in `receiveLoop`/`handlePacket`

`NWListener(using:.udp,on:port)` binds every interface (`0.0.0.0` + `::`), documented as intentional (`:17-23`) with the security boundary delegated to a VPN. The gap: binding all interfaces means the physical Wi-Fi/LAN interface is reachable **regardless of whether the VPN is up**, and nothing in-repo adds a host firewall rule. OSC carries no auth/encryption, and `handlePacket` accepts any datagram from any source. On untrusted Wi-Fi, a LAN peer can (a) deliver the C2 crash bomb, or (b) inject forged `/muse/eeg` samples straight into `continuation.yield` (`:266`) → the intent classifier → the "typing"/action pipeline — forging the user's selections. Only bites in opt-in `oscRemote` mode, hence Medium.

**Fix:** bind the intended interface only (`127.0.0.1`/`::1` via a local relay, or the resolved VPN interface address), or use `NWParameters` `requiredInterface`/`prohibitedInterfaceTypes`; at minimum filter by source peer/subnet in `receiveLoop`, add a per-packet size cap before decode, and document the required firewall rule. Treat every accepted sample as untrusted.

### M5 — App is not sandboxed; the no-network invariant is convention, not OS-enforced (CWE-693)
No `*.entitlements` in-repo; `package-app-bundle.sh:105` and `sign-app-local.sh:69` sign without `--entitlements`; `CLAUDE.md:3`

There is no App Sandbox, so `CLAUDE.md`'s "No network at runtime. No cloud. No telemetry." holds only by code convention + MLX-isolation discipline — a bug or any transitive dependency (`mlx-swift`, `swift-transformers`, …) opening an outbound socket would exfiltrate EEG/PII with no OS backstop. Separately, `CLAUDE.md:3`'s flat invariant is **not reconciled** with the new inbound OSC listener (the real carve-out is "no runtime network except BCICloudBridge/ClaudeCLIGenerator" — inbound LAN OSC is a *third* runtime network surface: opt-in, banner-surfaced, ingress-only, but unnamed in the doc).

**Fix:** ship an `.entitlements` enabling App Sandbox with `com.apple.security.network.server` (the OSC listener) + Bluetooth/mic/speech, and **deliberately omit** `com.apple.security.network.client` so outbound is OS-blocked (the `claude` CLI exception runs as a separate process). Pass `--entitlements` in both signing scripts. Update `CLAUDE.md` to name the inbound OSC listener as an explicit, opt-in, ingress-only exception.

### M6 — Signing script installs a self-signed trust anchor with an ACL-free key (CWE-732)
`Scripts/sign-app-local.sh:56` (`security import … -A`), `:59` (`security add-trusted-cert -r trustRoot -p codeSign`)

`:56` imports the private key with `-A` (any app may use it, no keychain-ACL prompt); `:59` installs the cert as a **trusted code-signing root** in the login keychain for 10 years (`:49`). Together, any local process running as the user can sign arbitrary Mach-O/bundles with a key the OS then treats as validly signed under the codeSign policy — a durable local code-signing-abuse primitive that defeats `codesign --verify` trust checks. Scoped to the dev account, but real.

**Fix:** drop `-A` (let the keychain ACL gate use); prefer `add-trusted-cert` *without* `-r trustRoot` (a plain self-signed identity is enough for a *stable* TCC code identity); shorten validity well below 10 years; document manual revocation (`security delete-certificate`) after the dev session.

### M7 — Demean can let a dead/floating electrode read `.healthy`
`Sources/NeuralComposeApp/AppViewModel.swift:1439-1445`; `Sources/BCIEEG/EEGChannelHealthProvider.swift:209-223`; `ChannelHealthThresholds.swift:66-70`

Both paths RMS the **demeaned** signal, then bucket into "healthy" (`[5,200]µV`; `[deadRMS=2,200]µV`). Demeaning is necessary to reject the ~800µV Muse DC baseline — but that DC offset is also the primary tell of a lifted/floating electrode. Strip it, and a floating electrode carrying only small ambient AC noise (~5–30µV RMS) lands in the "healthy" band and reads `.healthy` while carrying zero brain signal. The false-positive (dead→healthy) direction is reachable; a flat/railed sub-`deadRMS` electrode is still caught, so the gap is the moderate-AC-noise floating case. Thresholds self-identify as unvalidated heuristics.

**Fix:** add a shape check (flatness/kurtosis or line-noise band power) or an impedance-style signal rather than demeaned-RMS-in-band alone; at minimum document that "healthy" here asserts "AC amplitude in band", not "electrode contact confirmed."

---

## LOW (nice-to-have)

- **L1 — `computeCalibrationMetrics` skipped by the demean fix.** `AppViewModel.swift:1408-1415` still RMSes the *raw* window (DC-inflated ~800µV on live OSC data — the exact misreport the fix corrected everywhere else) and lacks the empty-channel guard the three fixed sites have (`sqrt(sumSq/count)` → `NaN`). **Fix:** demean + guard `count == 0` here too.
- **L2 — Cross-sender timestamp inversion.** `MindMonitorOSCStream.swift:102-109,257,284-289`: with ≥2 connections, concurrent `handlePacket`s can `yield` out of `elapsedSeconds` order, and `interArrivalMillis` interleaves both flows (meaningless jitter). Single phone = one connection, so low impact. **Fix:** a single-active-connection guard or a comment.
- **L3 — `codesign --deep` for signing.** `sign-app-local.sh:69`, `package-app-bundle.sh:105`: deprecated by Apple for signing (verification-only); re-signs the embedded MLX/Metal resources + `SpectralProbe` with the dev identity and can yield an inconsistently-sealed bundle. **Fix:** sign nested code inside-out without `--deep`; reserve `--deep` for `--verify`.
- **L4 — Hardcoded transient p12 password.** `sign-app-local.sh:28`: protects an ephemeral `mktemp` p12 deleted on `trap EXIT`; not a live credential (the durable secret is the M6 key). Informational; `openssl rand` would remove the pattern.
- **L5 — Sub-threshold.** `start()` TOCTOU (only matters under concurrent `start()` on one instance, which the supervisor never does); dead `NWEndpoint.Port(rawValue:) ?? 5000` (every `UInt16` is valid); heartbeat uses wall-clock `Date()` while inter-arrival uses monotonic `DispatchTime`, so an NTP step could nudge the watchdog.

---

## Verified and deliberately NOT reported (no-noise guarantee)

- **Concurrency model is sound** — every mutable field in `MindMonitorOSCStream` is lock-guarded; `continuation.yield` is correctly unlocked; the watchdog touches only immutable/locked state. No data race (the ≥2-connection issue is ordering, L2, not memory safety).
- **Parser bounds are safe** — over-read (`readBigEndianU32` 4-byte guard `:175`), unterminated/over-padded string (`readOSCString` `:151-165`), integer overflow on `Int(readBigEndianU32)` (lossless on LP64, then distance-guarded `:98`), zero-size-element infinite loop (advances 4 bytes then throws `.tooShort`), and attacker-length allocation blowup (bounded by the ≤64 KB datagram) — **all checked and refuted.** C2 (depth) is the one genuine parser defect.
- **The three demean computations are numerically correct** (empty-guarded, correct mean-subtract-then-RMS); the defect is the *heuristic* (M7), not the arithmetic.
- **The degrade does publish** (M3 refutes the "fake data with nothing shown" concern); the weakness is visual ambiguity, not a missing publish.

---

## Test gaps (to close alongside the fixes)

1. **Sample-throughput watchdog** — feed non-EEG traffic while EEG stops; assert the stream fails (guards C1).
2. **Deep-nesting DoS** — feed a deeply-nested bundle; assert a thrown error, not a crash (guards C2).
3. **Dead→healthy demean bucket** — a demeaned small-AC-noise channel must *not* read `.healthy` once M7 is addressed.
4. **Runtime fallback-to-synthetic** — supervisor retry-exhaustion → `makeSynthetic()`; assert the banner flips and the fallback is visually distinct (M3).
5. **Dropped-vs-ignored counters** — non-EEG messages must not increment a loss metric (H2).
6. **Multi-connection ordering** — two senders; assert monotonic timestamps or a single-active-connection guard (L2).
7. **Intentional bind** — assert the listener bind surface is deliberate (documents M4's decision).

---

*Lenses: `pr-review-toolkit:code-reviewer`, `pr-review-toolkit:silent-failure-hunter`, `code-modernization:security-auditor`. Fixing the findings is a gated follow-on (branch → PR → review-before-merge), triaged from this punch list — not part of this read-only pass.*
