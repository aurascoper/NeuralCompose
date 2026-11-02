#!/usr/bin/env bash
#
# create-dmg.sh — create a local drag-to-Applications disk image from the
# release app bundle built by package-macos-app.sh.
#
# Usage:
#   ./Scripts/create-dmg.sh
#   ./Scripts/create-dmg.sh --app dist/NeuralCompose.app
#   ./Scripts/create-dmg.sh --sign 'Developer ID Application: Name (TEAMID)'

set -euo pipefail

APP_NAME="NeuralCompose"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$REPO_ROOT/dist/$APP_NAME.app"
OUTPUT_PATH=""
SIGNING_IDENTITY=""

usage() {
    printf '%s\n' \
        "Usage: ./Scripts/create-dmg.sh [options]" \
        "" \
        "Options:" \
        "  --app PATH                   Bundle to place in the disk image." \
        "  --output PATH                Destination .dmg path." \
        "  --sign IDENTITY              Sign the finished disk image." \
        "  -h, --help                   Show this help."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_PATH="$2"; shift 2 ;;
        --output) OUTPUT_PATH="$2"; shift 2 ;;
        --sign) SIGNING_IDENTITY="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found: $APP_PATH" >&2
    echo "Build it first with ./Scripts/package-macos-app.sh" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
if [[ -z "$OUTPUT_PATH" ]]; then
    OUTPUT_PATH="$(dirname "$APP_PATH")/$APP_NAME-$VERSION.dmg"
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
STAGE_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

ditto "$APP_PATH" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$OUTPUT_PATH"

hdiutil verify "$OUTPUT_PATH"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$OUTPUT_PATH"
fi

echo "Created: $OUTPUT_PATH"
