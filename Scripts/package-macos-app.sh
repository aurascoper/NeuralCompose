#!/usr/bin/env bash
#
# package-macos-app.sh — build NeuralCompose for release and turn the SwiftPM
# executable into a relocatable macOS application bundle.
#
# Usage:
#   ./Scripts/package-macos-app.sh
#   ./Scripts/package-macos-app.sh --with-brainflow
#   ./Scripts/package-macos-app.sh --skip-build --sign 'Developer ID Application: Name (TEAMID)'
#
# The development-only .build/NeuralCompose.app wrapper remains useful for
# local TCC tests. This script writes the distributable artifact to dist/.

set -euo pipefail

APP_NAME="NeuralCompose"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/release"
DIST_DIR="$REPO_ROOT/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
PLIST_SOURCE="$REPO_ROOT/Sources/NeuralComposeApp/Resources/Info.plist"
ICON_SOURCE="$REPO_ROOT/Sources/NeuralComposeApp/Resources/NeuralCompose.icns"
SIGNING_IDENTITY="-"
SKIP_BUILD=0
USE_BRAINFLOW=0
BRAINFLOW_PATH=""

usage() {
    printf '%s\n' \
        "Usage: ./Scripts/package-macos-app.sh [options]" \
        "" \
        "Options:" \
        "  --skip-build                 Package the existing release executable." \
        "  --with-brainflow             Build with the installed BrainFlow runtime." \
        "  --brainflow-path=PATH        Override the BrainFlow source/runtime path." \
        "  --sign IDENTITY              Sign with a Developer ID instead of ad-hoc signing." \
        "  --output PATH                Write the .app bundle to this path." \
        "  -h, --help                   Show this help."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --with-brainflow) USE_BRAINFLOW=1; shift ;;
        --brainflow-path=*) BRAINFLOW_PATH="${1#*=}"; shift ;;
        --sign) SIGNING_IDENTITY="$2"; shift 2 ;;
        --output) APP_PATH="$2"; DIST_DIR="$(dirname "$APP_PATH")"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    build_args=(--release)
    if [[ "$USE_BRAINFLOW" -eq 1 ]]; then
        build_args+=(--with-brainflow)
    fi
    if [[ -n "$BRAINFLOW_PATH" ]]; then
        build_args+=("--brainflow-path=$BRAINFLOW_PATH")
    fi
    "$REPO_ROOT/Scripts/build.sh" "${build_args[@]}"
fi

# `.build/release` is a compatibility symlink on current SwiftPM releases.
# Resolve it so `find` sees resource bundles in the architecture-specific
# configuration directory instead of stopping at the symlink itself.
BUILD_DIR="$(cd "$BUILD_DIR" && pwd -P)"

for required in "$BUILD_DIR/$APP_NAME" "$PLIST_SOURCE" "$ICON_SOURCE"; do
    if [[ ! -e "$required" ]]; then
        echo "Required packaging input is missing: $required" >&2
        exit 1
    fi
done

if [[ ! -x "$BUILD_DIR/$APP_NAME" ]]; then
    echo "Release executable is not executable: $BUILD_DIR/$APP_NAME" >&2
    exit 1
fi

plutil -lint "$PLIST_SOURCE" >/dev/null

mkdir -p "$DIST_DIR"
rm -rf "$APP_PATH"
mkdir -p \
    "$APP_PATH/Contents/MacOS" \
    "$APP_PATH/Contents/Resources" \
    "$APP_PATH/Contents/Frameworks"

cp "$BUILD_DIR/$APP_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"
cp "$PLIST_SOURCE" "$APP_PATH/Contents/Info.plist"
cp "$ICON_SOURCE" "$APP_PATH/Contents/Resources/NeuralCompose.icns"

# SwiftPM's generated `Bundle.module` accessor looks for a package resource
# bundle at `Bundle.main.bundleURL/<name>.bundle`. Put the real resource data
# in Contents/Resources, then add a Contents-level symlink so that standalone
# SwiftPM accessors still resolve it without making codesign treat the raw data
# directory as a nested code bundle.
while IFS= read -r -d '' resource_bundle; do
    resource_name="$(basename "$resource_bundle")"
    cp -R "$resource_bundle" "$APP_PATH/Contents/Resources/$resource_name"
    ln -s "Resources/$resource_name" "$APP_PATH/Contents/$resource_name"
done < <(find "$BUILD_DIR" -maxdepth 1 -type d -name '*.bundle' -print0)

# SpectralProbe is a sibling subprocess used by the live spectral estimator.
if [[ -x "$BUILD_DIR/SpectralProbe" ]]; then
    cp "$BUILD_DIR/SpectralProbe" "$APP_PATH/Contents/MacOS/SpectralProbe"
fi

# build.sh copies BrainFlow and SimpleBLE dylibs next to the executable. Put
# them in the standard Frameworks directory and normalize their load paths.
shopt -s nullglob
for dylib in "$BUILD_DIR"/*.dylib; do
    [[ -f "$dylib" ]] || continue
    cp "$dylib" "$APP_PATH/Contents/Frameworks/"
done
shopt -u nullglob

add_rpath_if_missing() {
    local target="$1"
    local rpath="$2"
    if ! otool -l "$target" | awk -v expected="$rpath" '$1 == "path" && $2 == expected { found = 1 } END { exit(found ? 0 : 1) }'; then
        install_name_tool -add_rpath "$rpath" "$target"
    fi
}

rewrite_bundle_dependencies() {
    local target="$1"
    local dependency basename

    while IFS= read -r dependency; do
        basename="${dependency##*/}"
        if [[ -f "$APP_PATH/Contents/Frameworks/$basename" && "$dependency" != "@rpath/$basename" ]]; then
            install_name_tool -change "$dependency" "@rpath/$basename" "$target"
        fi
    done < <(otool -L "$target" | awk 'NR > 1 { print $1 }')
}

rewrite_bundle_dependencies "$APP_PATH/Contents/MacOS/$APP_NAME"
add_rpath_if_missing "$APP_PATH/Contents/MacOS/$APP_NAME" '@executable_path/../Frameworks'

if [[ -x "$APP_PATH/Contents/MacOS/SpectralProbe" ]]; then
    rewrite_bundle_dependencies "$APP_PATH/Contents/MacOS/SpectralProbe"
    add_rpath_if_missing "$APP_PATH/Contents/MacOS/SpectralProbe" '@executable_path/../Frameworks'
fi

shopt -s nullglob
for bundled_dylib in "$APP_PATH/Contents/Frameworks/"*.dylib; do
    bundled_name="$(basename "$bundled_dylib")"
    install_name_tool -id "@rpath/$bundled_name" "$bundled_dylib"
    rewrite_bundle_dependencies "$bundled_dylib"
    add_rpath_if_missing "$bundled_dylib" '@loader_path'
done
shopt -u nullglob

verify_bundle_dependencies() {
    local target dependency dependency_name audit_exit=0

    for target in \
        "$APP_PATH/Contents/MacOS/$APP_NAME" \
        "$APP_PATH/Contents/MacOS/SpectralProbe" \
        "$APP_PATH/Contents/Frameworks/"*.dylib; do
        [[ -e "$target" ]] || continue

        while IFS= read -r dependency; do
            case "$dependency" in
                /System/*|/usr/lib/*)
                    ;;
                @rpath/*)
                    dependency_name="${dependency##*/}"
                    if [[ ! -f "$APP_PATH/Contents/Frameworks/$dependency_name" ]]; then
                        echo "Unresolved bundled dependency: $target -> $dependency" >&2
                        audit_exit=1
                    fi
                    ;;
                @loader_path/*|@executable_path/*)
                    # A relocated dependency may deliberately be relative to
                    # its loader. The current bundle normalizes local dylibs
                    # to @rpath, but accept these standard Mach-O forms.
                    ;;
                *)
                    echo "External non-system dependency: $target -> $dependency" >&2
                    audit_exit=1
                    ;;
            esac
        done < <(otool -L "$target" | awk 'NR > 1 { print $1 }')
    done

    return "$audit_exit"
}

if ! verify_bundle_dependencies; then
    echo "Refusing to sign a bundle with unresolved dynamic dependencies." >&2
    exit 1
fi

sign_one() {
    local target="$1"
    if [[ "$SIGNING_IDENTITY" == "-" ]]; then
        codesign --force --sign - "$target"
    else
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$target"
    fi
}

# Sign nested code first. --deep is deliberately reserved for verification;
# signing nested code explicitly avoids hiding an incorrectly sealed payload.
while IFS= read -r -d '' dylib; do
    sign_one "$dylib"
done < <(find "$APP_PATH/Contents/Frameworks" -type f -name '*.dylib' -print0)

if [[ -x "$APP_PATH/Contents/MacOS/SpectralProbe" ]]; then
    sign_one "$APP_PATH/Contents/MacOS/SpectralProbe"
fi

# SwiftPM's .bundle directories here contain data resources, not nested code.
# The final app signature seals them as resources; attempting to sign them as
# code fails because they intentionally carry no bundle executable or Info.plist.

sign_one "$APP_PATH/Contents/MacOS/$APP_NAME"
sign_one "$APP_PATH"

plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Packaged: $APP_PATH"
echo "Dependency audit: all non-system dependencies are bundled."
otool -L "$APP_PATH/Contents/MacOS/$APP_NAME"
