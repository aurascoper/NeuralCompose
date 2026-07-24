#!/usr/bin/env bash
#
# smoke-packaged-resources.sh — prove a packaged .app can actually load its
# prompt resources.
#
# Why this exists: a packaged /Applications/NeuralCompose.app crashed with
# SIGTRAP on the main thread inside SwiftPM's generated NSBundle.module
# accessor, reached from PromptProfile.load() → LiveRuntimeFactory.make() →
# AppViewModel.ensureHypnagogicLoopRunning(). Bundle.module is a `static let`
# whose generated initializer calls fatalError(), so a missing resource bundle
# trapped the process during dispatch_once — before any Swift error existed,
# and out of reach of try/catch.
#
# `swift build` and `swift test` could not see it: SwiftPM leaves the resource
# bundle beside the binary in .build/<config>/, where lookup succeeds. Only the
# packaged layout was broken. This script exercises that layout.
#
# It deliberately does NOT launch the GUI app: that needs window-server access
# and would raise TCC prompts for mic/speech. Instead it drives the real
# locator against the real packaged bundle, which is what the app does at
# startup, and additionally checks that packaging fails loudly when the bundle
# is absent.
#
# Usage:
#   ./Scripts/smoke-packaged-resources.sh [--release]
#
# Exit 0 = packaged resources present, loadable, signed, and the packaging
# guard fires when they are missing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG="debug"
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG="release" ;;
        --debug)   CONFIG="debug" ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

BUNDLE_NAME="NeuralCompose_BCICloudBridge.bundle"
PROMPTS=(hypnagogic.md waking-dialectical.md witness.md)
APP="$REPO_ROOT/.build/NeuralCompose.app"

echo "▸ building ($CONFIG)"
if [[ "$CONFIG" == "release" ]]; then swift build -c release >/dev/null
else swift build >/dev/null; fi

echo "▸ packaging"
./Scripts/package-app-bundle.sh $([[ "$CONFIG" == "release" ]] && echo --release) >/dev/null

RES="$APP/Contents/Resources"

echo "▸ resource layout"
[[ -d "$RES/$BUNDLE_NAME" ]] || { echo "FAIL: $RES/$BUNDLE_NAME missing" >&2; exit 1; }
for p in "${PROMPTS[@]}"; do
    [[ -f "$RES/$BUNDLE_NAME/$p" ]] || { echo "FAIL: $BUNDLE_NAME/$p missing" >&2; exit 1; }
    [[ -s "$RES/$BUNDLE_NAME/$p" ]] || { echo "FAIL: $BUNDLE_NAME/$p is empty" >&2; exit 1; }
    echo "  ✓ $BUNDLE_NAME/$p"
done

echo "▸ signature"
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    echo "  ✓ codesign --verify passed"
else
    echo "FAIL: codesign --verify failed on $APP" >&2; exit 1
fi

echo "▸ loading through the real locator (PackagedAppResourceTests)"
# Insist the tests actually ran. They XCTSkip when no packaged app is found,
# and a skip must not read as a pass — that is the failure mode this whole
# script exists to catch.
loader_out="$(swift test --filter PackagedAppResourceTests 2>&1)"
if ! grep -qE "Executed 2 tests, with 0 failures" <<<"$loader_out"; then
    echo "FAIL: packaged-layout loader tests did not run clean" >&2
    grep -E "Test Case|skipped|Executed [0-9]+ test|error:" <<<"$loader_out" >&2 || true
    exit 1
fi
if grep -q "skipped" <<<"$loader_out"; then
    echo "FAIL: packaged-layout loader tests skipped — no app was found" >&2
    exit 1
fi
echo "  ✓ all $(grep -c "' passed" <<<"$loader_out") packaged-layout loads succeeded"

# Negative case: packaging must refuse to sign an app with no prompt bundle,
# so a regression is a build failure here rather than a user-visible one.
echo "▸ packaging guard fires when the bundle is absent"
GUARD_TMP="$(mktemp -d)"
trap 'rm -rf "$GUARD_TMP"' EXIT
mv "$REPO_ROOT/.build/$CONFIG/$BUNDLE_NAME" "$GUARD_TMP/"
guard_rc=0
./Scripts/package-app-bundle.sh $([[ "$CONFIG" == "release" ]] && echo --release) >/dev/null 2>&1 || guard_rc=$?
mv "$GUARD_TMP/$BUNDLE_NAME" "$REPO_ROOT/.build/$CONFIG/"
if [[ "$guard_rc" -eq 0 ]]; then
    echo "FAIL: packaging succeeded without $BUNDLE_NAME — the guard did not fire" >&2
    exit 1
fi
echo "  ✓ packaging exited $guard_rc with the bundle removed"

# Leave a correctly packaged app behind.
./Scripts/package-app-bundle.sh $([[ "$CONFIG" == "release" ]] && echo --release) >/dev/null

echo "▸ PASS — packaged prompt resources present, loadable, signed, and guarded"
