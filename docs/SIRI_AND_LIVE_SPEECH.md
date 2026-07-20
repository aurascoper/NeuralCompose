# Siri, Shortcuts & Live Speech with your Personal Voice

NeuralCompose speaks in your on-device **Personal Voice** (see `MODEL_SETUP.md` /
`Scripts/voice-profile.py`). This doc covers using that voice *outside* the app's
normal flow: hands-free via Siri, and system-wide via Live Speech.

## The one hard limit (read first)

**You cannot make Siri itself speak in your Personal Voice.** Apple keeps Siri's
voices and `AVSpeechSynthesizer`/Personal voices in separate domains — Siri voices
aren't exposed to the synthesis API, and there's no setting to use a Personal Voice
*as* Siri's voice (WWDC20 §10022). So the pattern is **Siri is the trigger, the app
is the mouth**: Siri runs a Shortcut → the Shortcut tells NeuralCompose to speak →
NeuralCompose speaks in *your* voice.

## Part 1 — Trigger NeuralCompose by voice (URL scheme + Shortcut)

The app registers the `neuralcompose://` URL scheme:

| URL | Effect |
| --- | --- |
| `neuralcompose://speak` | Speak the app's current composed sentence |
| `neuralcompose://speak?text=Hello%20world` | Speak arbitrary text ("speak this") |
| `neuralcompose://refine` | Refine the composed text |
| `neuralcompose://dictate` / `stop-dictation` | Start / stop dictation |
| `neuralcompose://reset` | Clear the composition |

Test it directly (app must be built + launched once so LaunchServices knows the
scheme — use `./Scripts/run-personal-voice.sh` so the Personal Voice grant holds):

```sh
open "neuralcompose://speak?text=This%20is%20my%20voice"
```

### Build the Siri Shortcut

1. Open **Shortcuts.app** → **+** (new shortcut).
2. (Optional, for "speak this") add **Ask for Input** (or **Dictate Text**) → type
   *"What should I say?"*.
3. Add **Open URLs** with:
   - fixed text: `neuralcompose://speak` — reads the composed sentence, or
   - `neuralcompose://speak?text=` then insert the **Provided Input** from step 2.
4. Name it **"Speak With My Voice"** (the name *is* the Siri phrase).
5. Say **"Hey Siri, Speak With My Voice."** Siri runs the Shortcut → the app speaks
   in your Personal Voice.

> Native "Hey Siri, <app action>" (App Intents) isn't wired: it needs Xcode's
> App-Intents metadata step, which this SwiftPM build doesn't run. The Shortcut
> route above gives the same "Hey Siri, …" result with no Team ID / entitlement.

## Part 2 — Your voice system-wide (Live Speech, zero code)

Live Speech is a built-in macOS accessibility feature: type anywhere (including
FaceTime/phone calls) and it speaks — in whatever voice you pick, **including your
Personal Voice**. It's not Siri, but it's the "my voice everywhere" outcome.

1. **System Settings → Accessibility → Live Speech → turn On.**
2. Set **Voice** to your Personal Voice (e.g. *Hunter's Personal Voice*).
3. Trigger it with the Live Speech shortcut (default: triple-press the Touch ID /
   power button, or set a keyboard shortcut in the same pane), type, and it speaks.

Open the pane directly:

```sh
open "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?LiveSpeech"
```

## Privacy

All of this stays on-device: the URL scheme is local (no network), Live Speech and
the Personal Voice are local, and none of it adds a network egress. The Personal
Voice grant is pinned to the app's code signature — keep signing with
`Scripts/sign-app-local.sh` so it persists across rebuilds.
