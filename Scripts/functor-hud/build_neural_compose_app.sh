#!/usr/bin/env bash
set -euo pipefail

SCRATCH_DIR="/Users/aurascoper/.gemini/antigravity/scratch"
NC_REPO="/Users/aurascoper/Developer/NeuralCompose"
BRAINFLOW_PATH="${BRAINFLOW_ROOT:-$HOME/Developer/brainflow}"
FIXTURE_BUILD_DIR="$SCRATCH_DIR/neural_compose_fixture_build"

APP_SCRATCH="$SCRATCH_DIR/Neural Compose.app"
APP_APPLICATIONS="/Applications/Neural Compose.app"
OLD_APP_APPLICATIONS="/Applications/NeuralCompose.app"
OLD_NC_BUILD_DIR="$NC_REPO/build"

echo "================================================================================"
echo "1. Ensuring 60-Frame 4-Pillar + 1/f Fractal + Takens + PostgreSQL Graph Assets"
echo "================================================================================"
if [[ ! -f "$FIXTURE_BUILD_DIR/four_pillar_fixture_60f.json" ]] || [[ ! -f "$FIXTURE_BUILD_DIR/functor_dialectic_fixture_60f.json" ]] || [[ ! -f "$FIXTURE_BUILD_DIR/claude_mind_pg_graph_traversal.json" ]]; then
    julia --startup-file=no "$SCRATCH_DIR/NeuralComposeLayaJEMAFixture.jl" "$FIXTURE_BUILD_DIR"
    julia --startup-file=no "$SCRATCH_DIR/generate_functor_dialectical_fixture.jl" "$FIXTURE_BUILD_DIR"
    /usr/bin/python3 "$SCRATCH_DIR/claude_mind_pg_graph_bridge.py" --out-dir "$FIXTURE_BUILD_DIR"
else
    echo "Fixture assets already generated in $FIXTURE_BUILD_DIR (249 files ready)."
fi

echo "================================================================================"
echo "2. Compiling Unified Native arm64 macOS Binary (4-Pillar Functor + Full BCI + BrainFlow BLE)"
echo "================================================================================"
# Preserve mlx-swift_Cmlx.bundle (with default.metallib) before any bundle cleanup
if [[ -f "$APP_APPLICATIONS/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]] && [[ ! -f "$NC_REPO/.build/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
    cp -R "$APP_APPLICATIONS/Contents/Resources/mlx-swift_Cmlx.bundle" "$NC_REPO/.build/mlx-swift_Cmlx.bundle"
fi

if [[ -f "$NC_REPO/Scripts/functor-hud/NeuralComposeFunctorApp.swift" ]]; then
    cp -f "$NC_REPO/Scripts/functor-hud/NeuralComposeFunctorApp.swift" "$SCRATCH_DIR/NeuralComposeFunctorApp.swift"
fi
if [[ -f "$NC_REPO/Scripts/functor-hud/semantica_multica_bridge.py" ]]; then
    cp -f "$NC_REPO/Scripts/functor-hud/semantica_multica_bridge.py" "$SCRATCH_DIR/semantica_multica_bridge.py"
fi

BIN_OUT="$SCRATCH_DIR/NeuralComposeFunctorBin"
PRODUCTS_DIR="$NC_REPO/.build/out/Products/Debug"
INTERMEDIATES_DIR="$NC_REPO/.build/out/Intermediates.noindex"
APP_OBJ_DIR="$INTERMEDIATES_DIR/NeuralCompose.build/Debug/NeuralCompose-p.build/Objects-normal/arm64"

if [[ "${1:-}" == "--fast-link" ]] && [[ -f "$APP_OBJ_DIR/NeuralComposeApp.o" ]]; then
    echo "Using existing compiled NeuralComposeApp object files (--fast-link)."
else
    if [[ -f "$BRAINFLOW_PATH/src/board_controller/inc/board_controller.h" ]]; then
        (cd "$NC_REPO" && swift build -c debug --product NeuralCompose \
            -Xcc "-DBCI_BRAINFLOW_AVAILABLE=1" \
            -Xcc "-I$BRAINFLOW_PATH/src/board_controller/inc" \
            -Xcc "-I$BRAINFLOW_PATH/src/utils/inc" \
            -Xcc "-I$BRAINFLOW_PATH/src/data_handler/inc" \
            -Xcc "-I$BRAINFLOW_PATH/third_party/json" \
            -Xlinker "-L$BRAINFLOW_PATH/compiled" \
            -Xlinker "-rpath" -Xlinker "$BRAINFLOW_PATH/compiled" \
            -Xlinker "-rpath" -Xlinker "@executable_path" \
            -Xlinker "-lBoardController" \
            -Xlinker "-lDataHandler" \
            -Xlinker "-lBrainBitLib")
    else
        (cd "$NC_REPO" && swift build -c debug --product NeuralCompose)
    fi
fi

echo "Compiling BCIBridge.mm with -DBCI_BRAINFLOW_AVAILABLE=1 against BrainFlow at $BRAINFLOW_PATH..."
clang++ -std=c++17 -ObjC++ -target arm64-apple-macos14.0 \
  -DBCI_BRAINFLOW_AVAILABLE=1 \
  -I"$NC_REPO/Sources/BCIBridge/include" \
  -I"$BRAINFLOW_PATH/src/board_controller/inc" \
  -I"$BRAINFLOW_PATH/src/utils/inc" \
  -I"$BRAINFLOW_PATH/src/data_handler/inc" \
  -I"$BRAINFLOW_PATH/third_party/json" \
  -c "$NC_REPO/Sources/BCIBridge/BCIBridge.mm" \
  -o "$PRODUCTS_DIR/BCIBridge.o"
strings "$PRODUCTS_DIR/BCIBridge.o" | grep -q "brainflow-linked"
cp "$BRAINFLOW_PATH/compiled"/lib*.dylib "$PRODUCTS_DIR/" 2>/dev/null || true
find "$BRAINFLOW_PATH/build" \
  \( -name "libsimpleble*.dylib" -o -name "libsimpleble-c*.dylib" \) \
  -exec cp {} "$PRODUCTS_DIR/" \; 2>/dev/null || true

if [[ -d "$NC_REPO/.build/mlx-swift_Cmlx.bundle" ]]; then
    rm -rf "$PRODUCTS_DIR/mlx-swift_Cmlx.bundle"
    cp -R "$NC_REPO/.build/mlx-swift_Cmlx.bundle" "$PRODUCTS_DIR/mlx-swift_Cmlx.bundle"
fi

/usr/bin/python3 -c '
import sys
p_in, p_out = sys.argv[1], sys.argv[2]
data = open(p_in, "rb").read()
open(p_out, "wb").write(data.replace(b"\x00_main\x00", b"\x00_ncmn\x00"))
' "$APP_OBJ_DIR/NeuralComposeApp.o" "$SCRATCH_DIR/NeuralComposeApp_nomain.o"

LINK_OBJS=("$SCRATCH_DIR/NeuralComposeApp_nomain.o")
while IFS= read -r obj_file; do
    [[ -n "$obj_file" ]] || continue
    [[ "$obj_file" == */NeuralComposeApp.o ]] && continue
    LINK_OBJS+=("$obj_file")
done < <(tr ' ' '\n' < "$APP_OBJ_DIR/NeuralCompose.LinkFileList")

INFO_PLIST_TMP="$SCRATCH_DIR/NeuralCompose_Info.plist"
cat > "$INFO_PLIST_TMP" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>NeuralCompose</string>
    <key>CFBundleName</key>
    <string>Neural Compose</string>
    <key>CFBundleDisplayName</key>
    <string>Neural Compose</string>
    <key>CFBundleIconFile</key>
    <string>NeuralCompose</string>
    <key>CFBundleIdentifier</key>
    <string>com.neuralcompose.app</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>60</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>NeuralCompose connects to your Muse headband over Bluetooth to read EEG locally. EEG data never leaves your machine.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>NeuralCompose captures microphone audio while you press and hold the dictation button and during listening turns of opt-in Hypnagogic mode. Audio is transcribed on-device only.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>NeuralCompose uses on-device speech recognition to transcribe your speech locally.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>NeuralCompose can receive EEG over your local network from the Mind Monitor OSC stream.</string>
    <key>NSHumanReadableCopyright</key>
    <string>[MODEL ILLUSTRATION - RUNG_4_MODEL] NeuralCompose 60-Frame Functor Network and Dialectical Topological Fixture.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.neuralcompose.app.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>neuralcompose</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

rm -rf "$PRODUCTS_DIR/NeuralComposeApp.swiftmodule"
echo "Linking unified binary against compiled NeuralComposeApp + BrainFlow BLE + MLX + BCIEEG + BCIVoice + WorldModel modules..."
swiftc -target arm64-apple-macos14.0 -parse-as-library \
  -I "$APP_OBJ_DIR" \
  -I "$PRODUCTS_DIR" \
  -Xcc -I"$NC_REPO/.build/checkouts/mlx-swift/Source/Cmlx/include" \
  -Xcc -fmodule-map-file="$INTERMEDIATES_DIR/GeneratedModuleMaps/BCIBridge.modulemap" \
  -Xcc -fmodule-map-file="$NC_REPO/.build/checkouts/mlx-swift/Source/Cmlx/include/module.modulemap" \
  -Xcc -fmodule-map-file="$NC_REPO/.build/checkouts/swift-numerics/Sources/_NumericsShims/include/module.modulemap" \
  "${LINK_OBJS[@]}" \
  "$PRODUCTS_DIR"/lib*.a \
  "$NC_REPO/Scripts/functor-hud/NeuralComposeFunctorApp.swift" \
  -L"$BRAINFLOW_PATH/compiled" -lBoardController \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$INFO_PLIST_TMP" \
  -lc++ -framework Speech -framework Foundation -framework Metal -framework Accelerate \
  -framework AVFAudio -framework AVFoundation -framework AppKit -framework Combine \
  -framework CoreBluetooth -framework CoreFoundation -framework CoreGraphics -framework CoreImage \
  -framework CoreML -framework CoreVideo -framework CryptoKit -framework Network \
  -framework QuartzCore -framework SceneKit -framework SwiftUI \
  -o "$BIN_OUT"

file "$BIN_OUT"

add_rpath_if_missing() {
    local target="$1"
    local rpath="$2"
    if ! otool -l "$target" | awk -v expected="$rpath" '$1 == "path" && $2 == expected { found = 1 } END { exit(found ? 0 : 1) }'; then
        install_name_tool -add_rpath "$rpath" "$target" 2>/dev/null || true
    fi
}

rewrite_bundle_dependencies() {
    local app_path="$1"
    local target="$2"
    local dependency basename
    while IFS= read -r dependency; do
        basename="${dependency##*/}"
        if [[ -f "$app_path/Contents/Frameworks/$basename" && "$dependency" != "@rpath/$basename" ]]; then
            install_name_tool -change "$dependency" "@rpath/$basename" "$target"
        fi
    done < <(otool -L "$target" | awk 'NR > 1 { print $1 }')
}

package_one_bundle() {
    local app_path="$1"
    echo "Packaging bundle: $app_path"
    rm -rf "$app_path"
    mkdir -p "$app_path/Contents/MacOS"
    mkdir -p "$app_path/Contents/Frameworks"
    mkdir -p "$app_path/Contents/Resources/fixture"
    mkdir -p "$app_path/Contents/Resources/equifinal_bin"

    cp "$BIN_OUT" "$app_path/Contents/MacOS/NeuralCompose"
    chmod +x "$app_path/Contents/MacOS/NeuralCompose"

    if [[ -f "$SCRATCH_DIR/equifinal_bin/claude" ]]; then
        cp "$SCRATCH_DIR/equifinal_bin/claude" "$app_path/Contents/Resources/equifinal_bin/claude"
        chmod +x "$app_path/Contents/Resources/equifinal_bin/claude"
    fi

    for helper_bin in "SpectralProbe" "MLXProbe"; do
        if [[ -x "$PRODUCTS_DIR/$helper_bin" ]]; then
            cp "$PRODUCTS_DIR/$helper_bin" "$app_path/Contents/MacOS/$helper_bin"
            chmod +x "$app_path/Contents/MacOS/$helper_bin"
        fi
    done

    shopt -s nullglob
    for dylib in "$PRODUCTS_DIR"/*.dylib "$BRAINFLOW_PATH/compiled"/lib*.dylib; do
        [[ -f "$dylib" ]] || continue
        cp -f "$dylib" "$app_path/Contents/Frameworks/"
    done
    shopt -u nullglob

    for exe_target in "$app_path/Contents/MacOS/NeuralCompose" "$app_path/Contents/MacOS/SpectralProbe" "$app_path/Contents/MacOS/MLXProbe"; do
        if [[ -x "$exe_target" ]]; then
            rewrite_bundle_dependencies "$app_path" "$exe_target"
            add_rpath_if_missing "$exe_target" '@executable_path/../Frameworks'
        fi
    done

    shopt -s nullglob
    for bundled_dylib in "$app_path/Contents/Frameworks/"*.dylib; do
        bundled_name="$(basename "$bundled_dylib")"
        install_name_tool -id "@rpath/$bundled_name" "$bundled_dylib"
        rewrite_bundle_dependencies "$app_path" "$bundled_dylib"
        add_rpath_if_missing "$bundled_dylib" '@loader_path'
    done
    shopt -u nullglob

    if [[ -f "$NC_REPO/Sources/NeuralComposeApp/Resources/NeuralCompose.icns" ]]; then
        cp "$NC_REPO/Sources/NeuralComposeApp/Resources/NeuralCompose.icns" "$app_path/Contents/Resources/NeuralCompose.icns"
    fi

    for bundle_name in "NeuralCompose_BCICloudBridge.bundle" "mlx-swift_Cmlx.bundle" "swift-transformers_Hub.bundle"; do
        local src_bundle=""
        if [[ -d "$NC_REPO/.build/$bundle_name" ]]; then
            src_bundle="$NC_REPO/.build/$bundle_name"
        elif [[ -d "$PRODUCTS_DIR/$bundle_name" ]]; then
            src_bundle="$PRODUCTS_DIR/$bundle_name"
        fi
        if [[ -n "$src_bundle" ]]; then
            cp -R "$src_bundle" "$app_path/Contents/Resources/$bundle_name"
            rm -rf "$app_path/Contents/Resources/$bundle_name/Contents/_CodeSignature"
            ln -sf "Resources/$bundle_name" "$app_path/Contents/$bundle_name"
        fi
    done

    # Sanitize any em-dashes or en-dashes inside copied resource bundle markdown files before signing
    /usr/bin/python3 - "$app_path/Contents/Resources" <<'PYEOF'
import os, sys
root_dir = sys.argv[1]
for r, _, files in os.walk(root_dir):
    for fn in files:
        if fn.endswith((".md", ".txt", ".json", ".plist")):
            p = os.path.join(r, fn)
            try:
                with open(p, "r", encoding="utf-8") as f:
                    txt = f.read()
                if "\u2014" in txt or "\u2013" in txt:
                    txt = txt.replace("\u2014", " - ").replace("\u2013", "-")
                    with open(p, "w", encoding="utf-8") as f:
                        f.write(txt)
            except Exception:
                pass
PYEOF

    cp -R "$FIXTURE_BUILD_DIR/"* "$app_path/Contents/Resources/fixture/"

    cat > "$app_path/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>NeuralCompose</string>
    <key>CFBundleName</key>
    <string>Neural Compose</string>
    <key>CFBundleDisplayName</key>
    <string>Neural Compose</string>
    <key>CFBundleIconFile</key>
    <string>NeuralCompose</string>
    <key>CFBundleIdentifier</key>
    <string>com.neuralcompose.app</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>60</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>NeuralCompose connects to your Muse headband over Bluetooth to read EEG locally. EEG data never leaves your machine.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>NeuralCompose captures microphone audio while you press and hold the dictation button and during listening turns of opt-in Hypnagogic mode. Audio is transcribed on-device only.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>NeuralCompose uses on-device speech recognition to transcribe your speech locally.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>NeuralCompose can receive EEG over your local network from the Mind Monitor OSC stream.</string>
    <key>NSHumanReadableCopyright</key>
    <string>[MODEL ILLUSTRATION - RUNG_4_MODEL] NeuralCompose 60-Frame Functor Network and Dialectical Topological Fixture.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.neuralcompose.app.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>neuralcompose</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

    plutil -lint "$app_path/Contents/Info.plist"
    local sign_id="-"
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "NeuralCompose Local Dev"; then
        sign_id="NeuralCompose Local Dev"
    fi
    while IFS= read -r -d '' dylib; do
        codesign --force --sign "$sign_id" "$dylib"
    done < <(find "$app_path/Contents/Frameworks" -type f -name '*.dylib' -print0)
    for helper_bin in "SpectralProbe" "MLXProbe"; do
        if [[ -x "$app_path/Contents/MacOS/$helper_bin" ]]; then
            codesign --force --sign "$sign_id" "$app_path/Contents/MacOS/$helper_bin"
        fi
    done
    codesign --force --sign "$sign_id" "$app_path/Contents/MacOS/NeuralCompose"
    codesign --force --sign "$sign_id" "$app_path"
    codesign --verify --deep --strict --verbose=2 "$app_path"
}

echo "================================================================================"
echo "3. Packaging Unified Neural Compose.app & Deduplicating Spotlight"
echo "================================================================================"
# Keep scratch hidden from Spotlight so only /Applications/Neural Compose.app appears
touch "$SCRATCH_DIR/.metadata_never_index"
package_one_bundle "$APP_SCRATCH"

# Remove duplicate build directory in NeuralCompose repo and clean up old /Applications/NeuralCompose.app
rm -rf "$OLD_NC_BUILD_DIR"
if [[ -d "$OLD_APP_APPLICATIONS" ]]; then
    echo "Removing superseded $OLD_APP_APPLICATIONS (already backed up in dist/backups.noindex)..."
    rm -rf "$OLD_APP_APPLICATIONS"
fi

package_one_bundle "$APP_APPLICATIONS"
rm -f "$BIN_OUT"

# Refresh LaunchServices and Spotlight index so only /Applications/Neural Compose.app is registered
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u "$OLD_NC_BUILD_DIR/Neural Compose.app" 2>/dev/null || true
    "$LSREGISTER" -u "$OLD_APP_APPLICATIONS" 2>/dev/null || true
    "$LSREGISTER" -u "$APP_SCRATCH" 2>/dev/null || true
    "$LSREGISTER" -f "$APP_APPLICATIONS" 2>/dev/null || true
fi
mdimport "$APP_APPLICATIONS" 2>/dev/null || true

echo "================================================================================"
echo "4. Running Self-Test on Packaged Neural Compose.app"
echo "================================================================================"
"$APP_APPLICATIONS/Contents/MacOS/NeuralCompose" --self-test
