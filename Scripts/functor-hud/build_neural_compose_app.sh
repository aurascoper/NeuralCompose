#!/usr/bin/env bash
set -euo pipefail

SCRATCH_DIR="/Users/aurascoper/.gemini/antigravity/scratch"
NC_REPO="/Users/aurascoper/Developer/NeuralCompose"
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
echo "2. Compiling Unified Native arm64 macOS Binary (4-Pillar Functor + Full BCI App)"
echo "================================================================================"
BIN_OUT="$SCRATCH_DIR/NeuralComposeFunctorBin"
PROD_DEBUG="$NC_REPO/.build/out/Products/Debug"
INTERM_DIR="$NC_REPO/.build/out/Intermediates.noindex"
NATIVE_DEBUG="$NC_REPO/.build/arm64-apple-macosx/debug"

if [[ -d "$NATIVE_DEBUG/BCICore.build" ]] && [[ -d "$PROD_DEBUG" ]]; then
    echo "Syncing latest native-built BCICore.o and Prompt resources into $PROD_DEBUG..."
    ld -r "$NATIVE_DEBUG/BCICore.build/"*.o -o "$PROD_DEBUG/BCICore.o"
    if [[ -f "$NATIVE_DEBUG/Modules/BCICore.swiftmodule" ]]; then
        cp "$NATIVE_DEBUG/Modules/BCICore.swiftmodule" "$PROD_DEBUG/BCICore.swiftmodule/arm64-apple-macos.swiftmodule"
    fi
    if [[ -f "$NATIVE_DEBUG/Modules/BCICore.swiftdoc" ]]; then
        cp "$NATIVE_DEBUG/Modules/BCICore.swiftdoc" "$PROD_DEBUG/BCICore.swiftmodule/arm64-apple-macos.swiftdoc"
    fi
fi
if [[ -d "$PROD_DEBUG/NeuralCompose_BCICloudBridge.bundle/Contents/Resources" ]]; then
    cp "$NC_REPO/Sources/BCICloudBridge/Prompts/"*.md "$PROD_DEBUG/NeuralCompose_BCICloudBridge.bundle/Contents/Resources/"
fi

if [[ -f "$PROD_DEBUG/ExecutableModules/NeuralComposeApp-415ACE3B569506E-testable.o" ]]; then
    echo "Linking unified binary against compiled NeuralComposeApp + MLX + BCIEEG + BCIVoice + WorldModel modules..."
    swiftc -target arm64-apple-macos14.0 -parse-as-library \
      -I "$PROD_DEBUG" \
      -Xcc -fmodule-map-file="$INTERM_DIR/GeneratedModuleMaps/BCIBridge.modulemap" \
      -Xcc -fmodule-map-file="$NC_REPO/.build/checkouts/mlx-swift/Source/Cmlx/include/module.modulemap" \
      -Xcc -fmodule-map-file="$NC_REPO/.build/checkouts/swift-numerics/Sources/_NumericsShims/include/module.modulemap" \
      "$PROD_DEBUG/ExecutableModules/NeuralComposeApp-415ACE3B569506E-testable.o" \
      "$PROD_DEBUG/BCICore.o" "$PROD_DEBUG/BCIBridge.o" "$PROD_DEBUG/BCIEEG.o" "$PROD_DEBUG/BCIClassifier.o" \
      "$PROD_DEBUG/MLX.o" "$PROD_DEBUG/Cmlx.o" "$PROD_DEBUG/Numerics.o" "$PROD_DEBUG/_NumericsShims.o" \
      "$PROD_DEBUG/RealModule.o" "$PROD_DEBUG/ComplexModule.o" "$PROD_DEBUG/MLXNN.o" "$PROD_DEBUG/MLXRandom.o" \
      "$PROD_DEBUG/MLXFast.o" "$PROD_DEBUG/MLXLLM.o" "$PROD_DEBUG/MLXOptimizers.o" "$PROD_DEBUG/MLXLinalg.o" \
      "$PROD_DEBUG/Tokenizers.o" "$PROD_DEBUG/Generation.o" "$PROD_DEBUG/Models.o" "$PROD_DEBUG/Hub.o" \
      "$PROD_DEBUG/Jinja.o" "$PROD_DEBUG/OrderedCollections.o" "$PROD_DEBUG/InternalCollectionsUtilities.o" \
      "$PROD_DEBUG/TensorUtils.o" "$PROD_DEBUG/MLXLMCommon.o" "$PROD_DEBUG/MLXEmbedders.o" \
      "$PROD_DEBUG/BCILLM.o" "$PROD_DEBUG/BCIVoice.o" "$PROD_DEBUG/BCICloudBridge.o" "$PROD_DEBUG/BCIPeerBridge.o" \
      "$PROD_DEBUG/WorldModelDemo.o" \
      "$SCRATCH_DIR/NeuralComposeFunctorApp.swift" \
      -lc++ -framework Speech -framework Foundation -framework Metal -framework Accelerate \
      -framework AVFAudio -framework AVFoundation -framework AppKit -framework Combine \
      -framework CoreFoundation -framework CoreGraphics -framework CoreImage -framework CoreML \
      -framework CoreVideo -framework CryptoKit -framework Network -framework QuartzCore \
      -framework SceneKit -framework SwiftUI \
      -o "$BIN_OUT"
else
    echo "Compiling standalone 4-Pillar + BCICore binary..."
    swiftc -O -target arm64-apple-macos14.0 -parse-as-library \
      "$NC_REPO/Sources/BCICore/Models/Embedding.swift" \
      "$NC_REPO/Sources/BCICore/Models/SpectralState.swift" \
      "$NC_REPO/Sources/BCICore/Protocols/GenerationRuntime.swift" \
      "$NC_REPO/Sources/BCICore/Telemetry/GeneratorFingerprint.swift" \
      "$NC_REPO/Sources/BCICore/Dialectic/DialecticalCompetition.swift" \
      "$NC_REPO/Sources/BCICore/Dialectic/DialecticalDynamics.swift" \
      "$NC_REPO/Sources/BCICore/Dialectic/DialecticalField.swift" \
      "$NC_REPO/Sources/BCICore/Dialectic/DialecticalMemory.swift" \
      "$NC_REPO/Sources/BCICore/Dialectic/SemanticGraph.swift" \
      "$SCRATCH_DIR/NeuralComposeFunctorApp.swift" \
      -framework SwiftUI -framework SceneKit -framework AppKit -framework Metal -framework Foundation \
      -o "$BIN_OUT"
fi

file "$BIN_OUT"

package_one_bundle() {
    local app_path="$1"
    echo "Packaging bundle: $app_path"
    rm -rf "$app_path"
    mkdir -p "$app_path/Contents/MacOS"
    mkdir -p "$app_path/Contents/Resources/fixture"
    mkdir -p "$app_path/Contents/Resources/equifinal_bin"

    cp "$BIN_OUT" "$app_path/Contents/MacOS/NeuralCompose"
    chmod +x "$app_path/Contents/MacOS/NeuralCompose"

    if [[ -f "$SCRATCH_DIR/equifinal_bin/claude" ]]; then
        cp "$SCRATCH_DIR/equifinal_bin/claude" "$app_path/Contents/Resources/equifinal_bin/claude"
        chmod +x "$app_path/Contents/Resources/equifinal_bin/claude"
    fi

    if [[ -x "$PROD_DEBUG/SpectralProbe" ]]; then
        cp "$PROD_DEBUG/SpectralProbe" "$app_path/Contents/MacOS/SpectralProbe"
        chmod +x "$app_path/Contents/MacOS/SpectralProbe"
    fi

    if [[ -f "$NC_REPO/Sources/NeuralComposeApp/Resources/NeuralCompose.icns" ]]; then
        cp "$NC_REPO/Sources/NeuralComposeApp/Resources/NeuralCompose.icns" "$app_path/Contents/Resources/NeuralCompose.icns"
    fi

    for bundle_name in "NeuralCompose_BCICloudBridge.bundle" "mlx-swift_Cmlx.bundle" "swift-transformers_Hub.bundle"; do
        if [[ -d "$PROD_DEBUG/$bundle_name" ]]; then
            cp -R "$PROD_DEBUG/$bundle_name" "$app_path/Contents/Resources/$bundle_name"
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
    if [[ -x "$app_path/Contents/MacOS/SpectralProbe" ]]; then
        codesign --force --sign "$sign_id" "$app_path/Contents/MacOS/SpectralProbe"
    fi
    codesign --force --sign "$sign_id" "$app_path/Contents/MacOS/NeuralCompose"
    codesign --force --deep --sign "$sign_id" "$app_path"
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
